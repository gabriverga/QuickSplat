import * as THREE from "three";
import { OrbitControls } from "three/examples/jsm/controls/OrbitControls.js";
import { PLYLoader } from "three/examples/jsm/loaders/PLYLoader.js";
import { SparkRenderer, SplatMesh } from "@sparkjsdev/spark";

// The page stays loaded between previews: the plugin calls window.sqvOpen(info)
// for every file and window.sqvClear() when the preview closes.

const $ = (id) => document.getElementById(id);
const bar = $("bar"), barWrap = $("barwrap"), msg = $("msg"), hud = $("hud"), info = $("info");

const setMsg = (t, isErr = false) => {
  msg.textContent = t; msg.className = isErr ? "err" : ""; msg.style.display = t ? "block" : "none";
};
const store = {
  get(k, d) { try { const v = localStorage.getItem("sqv." + k); return v === null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem("sqv." + k, JSON.stringify(v)); } catch { /* ignore */ } },
};

// ---------- three.js (created once) ----------
const renderer = new THREE.WebGLRenderer({ antialias: false, powerPreference: "high-performance" });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.setClearColor(0x1e1e1e, 1);
document.body.appendChild(renderer.domElement);

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.01, 10000);
camera.position.set(0, 0, 5);

const controls = new OrbitControls(camera, renderer.domElement);
controls.enableDamping = true;
controls.dampingFactor = 0.12;
controls.screenSpacePanning = true;
controls.zoomToCursor = true;
controls.autoRotateSpeed = 1.5;

const spark = new SparkRenderer({ renderer });
scene.add(spark);

const lights = new THREE.Group();
lights.add(new THREE.HemisphereLight(0xffffff, 0x444444, 2.2));
const dl = new THREE.DirectionalLight(0xffffff, 1.5); dl.position.set(1, 2, 3); lights.add(dl);
lights.visible = false;
scene.add(lights);

// root carries the up-axis rotation
const root = new THREE.Group();
scene.add(root);

// ---------- state ----------
let current = null;     // { kind, object, pointsMat, fit, token }
let openToken = 0;

const ORIENT = [
  { label: "Y-down", rx: Math.PI },      // COLMAP / most 3DGS trainers
  { label: "Z-up", rx: -Math.PI / 2 },   // scanners, Metashape, CAD
  { label: "Y-up", rx: 0 },
];
let orient = 0;
const orientKey = (kind) => "orient." + kind;
function applyOrient() {
  root.rotation.set(ORIENT[orient].rx, 0, 0);
  root.updateMatrixWorld(true);
  $("btnAxis").textContent = "Up: " + ORIENT[orient].label;
}

function frame() {
  const fit = current?.fit;
  if (!fit) return;
  const c = fit.center.clone().applyMatrix4(root.matrixWorld);
  const dist = fit.radius / Math.sin(THREE.MathUtils.degToRad(camera.fov / 2)) * 0.9;
  const dir = new THREE.Vector3(0.6, 0.35, 1).normalize();
  controls.target.copy(c);
  camera.position.copy(c).addScaledVector(dir, dist);
  camera.near = Math.max(dist / 1000, 0.001);
  camera.far = dist * 200;
  camera.updateProjectionMatrix();
  controls.update();
}

// robust bounds (2–98 percentile) so far-away floaters don't ruin framing
function robustFit(xs, ys, zs) {
  const pct = (a, p) => a[Math.min(a.length - 1, Math.max(0, Math.floor(p * (a.length - 1))))];
  const sx = Float32Array.from(xs).sort(), sy = Float32Array.from(ys).sort(), sz = Float32Array.from(zs).sort();
  const min = new THREE.Vector3(pct(sx, 0.02), pct(sy, 0.02), pct(sz, 0.02));
  const max = new THREE.Vector3(pct(sx, 0.98), pct(sy, 0.98), pct(sz, 0.98));
  const size = max.clone().sub(min);
  return { center: min.clone().add(max).multiplyScalar(0.5), radius: Math.max(size.length() / 2, 1e-3), size };
}

const SAMPLES = 40000;

// ---------- download with progress (used for point clouds, and for splats on macOS) ----------
async function fetchBytes(o, token) {
  const res = await fetch(o.src);
  if (!res.ok) throw new Error("HTTP " + res.status);
  const total = Number(res.headers.get("content-length")) || o.size || 0;
  if (!res.body) {
    const ab = await res.arrayBuffer();
    return token === openToken ? new Uint8Array(ab) : null;
  }
  const reader = res.body.getReader();
  const chunks = []; let loaded = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (token !== openToken) { reader.cancel(); return null; }
    chunks.push(value); loaded += value.length;
    if (total) bar.style.width = (100 * loaded / total).toFixed(1) + "%";
  }
  const buf = new Uint8Array(loaded);
  let off = 0; for (const c of chunks) { buf.set(c, off); off += c.length; }
  return buf;
}

// ---------- splats ----------
const SPLAT_TYPES = { ply: "ply", spz: "spz", splat: "splat", ksplat: "ksplat", sog: "pcsogszip" };

async function loadSplat(o, token) {
  const ext = (o.name.split(".").pop() || "").toLowerCase();
  let mesh;
  if (o.mainThreadFetch) {
    // macOS WKWebView: files come from a custom URL scheme that workers can't reach,
    // so the page downloads the bytes and hands them to Spark.
    const bytes = await fetchBytes(o, token);
    if (!bytes) return null;
    mesh = new SplatMesh({ fileBytes: bytes, fileName: o.name, fileType: SPLAT_TYPES[ext] });
  } else {
    mesh = new SplatMesh({
      url: o.src,
      fileName: o.name,
      fileType: SPLAT_TYPES[ext],
      onProgress: (e) => {
        if (token === openToken && e.lengthComputable && e.total > 0) bar.style.width = (100 * e.loaded / e.total).toFixed(1) + "%";
      },
    });
  }
  await mesh.initialized;
  if (token !== openToken) { mesh.dispose?.(); return null; }

  const n = mesh.numSplats || mesh.packedSplats?.numSplats || 0;
  const xs = [], ys = [], zs = [];
  const ps = mesh.packedSplats;
  if (ps && typeof ps.getSplat === "function" && n > 0) {
    // random sampling: constant cost whatever the splat count
    const k = Math.min(n, SAMPLES);
    for (let j = 0; j < k; j++) {
      const c = ps.getSplat(k === n ? j : Math.floor(Math.random() * n)).center;
      xs.push(c.x); ys.push(c.y); zs.push(c.z);
    }
  } else {
    const stride = Math.max(1, Math.floor(n / SAMPLES));
    mesh.forEachSplat((i, c) => { if (i % stride === 0) { xs.push(c.x); ys.push(c.y); zs.push(c.z); } });
  }
  return {
    object: mesh,
    count: n,
    unit: "splats",
    fit: xs.length ? robustFit(xs, ys, zs) : { center: new THREE.Vector3(), radius: 1, size: new THREE.Vector3() },
  };
}

// ---------- point clouds / meshes (PLY) ----------
async function loadPoints(o, token) {
  const buf = await fetchBytes(o, token);
  if (!buf) return null;
  const geom = new PLYLoader().parse(buf.buffer.byteLength === buf.length ? buf.buffer : buf.slice().buffer);
  if (token !== openToken) { geom.dispose(); return null; }
  const hasColor = !!geom.getAttribute("color");
  const pos = geom.getAttribute("position");
  const n = pos.count;

  let object, pointsMat = null;
  if (geom.index && geom.index.count > 0) {
    geom.computeVertexNormals();
    object = new THREE.Mesh(geom, new THREE.MeshStandardMaterial({
      color: hasColor ? 0xffffff : 0xb0b0b0, vertexColors: hasColor, side: THREE.DoubleSide, roughness: 0.8 }));
  } else {
    pointsMat = new THREE.PointsMaterial({ size: store.get("pointSize", 2), sizeAttenuation: false,
      vertexColors: hasColor, color: hasColor ? 0xffffff : 0xcfcfcf });
    object = new THREE.Points(geom, pointsMat);
  }

  const stride = Math.max(1, Math.floor(n / SAMPLES));
  const xs = [], ys = [], zs = [];
  for (let i = 0; i < n; i += stride) { xs.push(pos.getX(i)); ys.push(pos.getY(i)); zs.push(pos.getZ(i)); }
  return { object, pointsMat, count: n, unit: geom.index ? "vertices" : "points", fit: robustFit(xs, ys, zs) };
}

// ---------- info panel ----------
const fmtBytes = (b) => {
  if (!b && b !== 0) return null;
  const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return (i ? b.toFixed(b < 10 ? 2 : 1) : b) + " " + u[i];
};
const fmtDate = (iso) => {
  if (!iso) return null;
  const d = new Date(iso);
  return isNaN(d) ? null : d.toLocaleString("en-GB", { day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit" });
};
const fmtNum = (v) => (Math.abs(v) >= 100 ? v.toFixed(0) : Math.abs(v) >= 10 ? v.toFixed(1) : v.toFixed(2));
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function renderInfo(o, r, secs) {
  const ext = (o.name.split(".").pop() || "").toUpperCase();
  const fmt = o.kind === "splat" ? (ext === "PLY" ? "3DGS PLY" : ext) : (r?.unit === "vertices" ? "Mesh PLY" : "Point cloud PLY");
  const rows = [];
  const l1 = [fmt];
  if (r) l1.push(`${r.count.toLocaleString("en-US")} ${r.unit}`);
  else if (o.vertexCount > 0) l1.push(`${Number(o.vertexCount).toLocaleString("en-US")} ${o.kind === "splat" ? "splats" : "points"}`);
  if (o.shDegree !== undefined && o.shDegree !== null && o.kind === "splat") l1.push(`SH ${o.shDegree}`);
  if (o.size) l1.push(fmtBytes(o.size));
  rows.push(l1.join(" · "));
  const created = fmtDate(o.created), modified = fmtDate(o.modified);
  if (created) rows.push(`<span class="k">Created</span> ${created}`);
  if (modified && modified !== created) rows.push(`<span class="k">Modified</span> ${modified}`);
  const l3 = [];
  if (r?.fit?.size) l3.push(`<span class="k">Extent</span> ${fmtNum(r.fit.size.x)} × ${fmtNum(r.fit.size.y)} × ${fmtNum(r.fit.size.z)}`);
  if (secs !== undefined) l3.push(`<span class="k">Loaded in</span> ${secs.toFixed(2)} s`);
  if (l3.length) rows.push(l3.join(" · "));
  if (o.comment) rows.push(`<span class="k">Note</span> ${esc(o.comment)}`);
  info.innerHTML = `<div class="t">${esc(o.name)}</div>` + rows.map((x) => `<div>${x}</div>`).join("");
  info.title = [o.path, ...(o.comments || [])].filter(Boolean).join("\n");
  info.style.display = "block";
}

// ---------- open / clear ----------
function disposeCurrent() {
  if (!current) return;
  const obj = current.object;
  root.remove(obj);
  try {
    if (obj.isSplatMesh || obj.dispose) obj.dispose?.();
    obj.geometry?.dispose?.();
    obj.material?.dispose?.();
  } catch { /* ignore */ }
  current = null;
  lights.visible = false;
}

window.sqvClear = function () {
  openToken++;
  disposeCurrent();
  info.style.display = "none";
  $("psWrap").style.display = "none";
  hud.classList.remove("ready");
  barWrap.style.display = "none";
  setMsg("");
};

window.sqvOpen = async function (o) {
  const token = ++openToken;
  disposeCurrent();
  window.__sqvReady = false; window.__sqvError = null;

  o.name = o.name || decodeURIComponent((o.src || "").split("/").pop().split("?")[0]);
  o.kind = o.kind || "splat";
  // COLMAP sparse clouds are Y-down like splats; other point clouds are usually Z-up
  o.orientGroup = o.kind === "points" && /sparse|points3d|colmap/i.test(o.name) ? "points-colmap" : o.kind;
  orient = store.get(orientKey(o.orientGroup), o.orientGroup === "points" ? 1 : 0) % ORIENT.length;
  applyOrient();

  bar.style.width = "0"; barWrap.style.display = "block"; setMsg("Loading…");
  hud.classList.remove("ready");
  $("psWrap").style.display = "none";
  renderInfo(o, null);

  try {
    const t0 = performance.now();
    const r = o.kind === "points" ? await loadPoints(o, token) : await loadSplat(o, token);
    if (!r || token !== openToken) return;
    current = { kind: o.kind, orientGroup: o.orientGroup, ...r };
    root.add(r.object);
    lights.visible = r.unit === "vertices";
    if (r.pointsMat) {
      $("psWrap").style.display = "flex";
      $("pointSize").value = r.pointsMat.size;
    }
    controls.autoRotate = $("btnRotate").classList.contains("on");
    frame();
    barWrap.style.display = "none"; setMsg("");
    renderInfo(o, r, (performance.now() - t0) / 1000);
    hud.classList.add("ready");
    window.__sqvReady = true;
  } catch (err) {
    if (token !== openToken) return;
    console.error(err);
    barWrap.style.display = "none";
    setMsg("Can't open this file: " + (err?.message || err), true);
    window.__sqvError = String(err?.message || err);
  }
};

// ---------- UI ----------
$("btnReset").onclick = () => frame();
$("btnAxis").onclick = () => {
  orient = (orient + 1) % ORIENT.length;
  if (current) store.set(orientKey(current.orientGroup), orient);
  applyOrient(); frame();
};
$("btnRotate").onclick = () => {
  controls.autoRotate = !controls.autoRotate;
  $("btnRotate").classList.toggle("on", controls.autoRotate);
};
$("pointSize").oninput = (e) => {
  const v = Number(e.target.value);
  if (current?.pointsMat) current.pointsMat.size = v;
  store.set("pointSize", v);
};
info.onclick = () => { info.classList.toggle("min"); store.set("infoMin", info.classList.contains("min")); };
if (store.get("infoMin", false)) info.classList.add("min");

// double click: move the orbit pivot to the clicked point
const raycaster = new THREE.Raycaster();
renderer.domElement.addEventListener("dblclick", (ev) => {
  if (!current) return;
  const ndc = new THREE.Vector2((ev.clientX / innerWidth) * 2 - 1, -(ev.clientY / innerHeight) * 2 + 1);
  raycaster.setFromCamera(ndc, camera);
  raycaster.params.Points.threshold = current.fit ? current.fit.radius * 0.004 : 0.01;
  let hit;
  try { hit = raycaster.intersectObject(current.object, false)[0]; } catch { return; }
  if (hit) {
    const delta = hit.point.clone().sub(controls.target);
    controls.target.add(delta); camera.position.add(delta); controls.update();
  }
});

window.addEventListener("keydown", (e) => {
  if (e.code === "KeyR") frame();
  else if (e.code === "KeyU") $("btnAxis").click();
  else if (e.code === "KeyA") $("btnRotate").click();
  else if (e.code === "KeyI") info.click();
});

window.addEventListener("resize", () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

// nothing to draw while a file is loading: skip frames so the main thread and GPU are free for loading
let blank = false;
renderer.setAnimationLoop(() => {
  if (!current) {
    if (!blank) { renderer.clear(); blank = true; }
    return;
  }
  blank = false;
  controls.update();
  renderer.render(scene, camera);
});

// standalone use / testing: index.html?src=...&kind=...
const qp = new URLSearchParams(location.search);
if (qp.get("src")) {
  window.sqvOpen({ src: qp.get("src"), kind: qp.get("kind") || "splat", name: qp.get("name") || undefined,
    size: Number(qp.get("size")) || undefined, created: qp.get("created") || undefined, modified: qp.get("modified") || undefined,
    shDegree: qp.get("sh") !== null ? Number(qp.get("sh")) : undefined, comment: qp.get("comment") || undefined, mainThreadFetch: qp.get("main") === "1" });
} else {
  setMsg("");
  barWrap.style.display = "none";
}
window.__sqvPageReady = true;
