# Usage: python3 tools/gen_test_data.py <output_dir>  (needs numpy)
import numpy as np, sys, struct
rng = np.random.default_rng(1)
out = sys.argv[1]
# --- 3DGS: colored torus + far-away floaters, COLMAP-style coordinates (Y down)
N = 150000
u = rng.uniform(0, 2*np.pi, N); v = rng.uniform(0, 2*np.pi, N)
R, r = 1.0, 0.35
x = (R + r*np.cos(v))*np.cos(u); z = (R + r*np.cos(v))*np.sin(u); y = -(r*np.sin(v)) - 0.0
# cube above the torus (Y-down, so negative y = up)
M = 30000
cube = rng.uniform(-0.25, 0.25, (M, 3)); cube[:,1] -= 0.9
F = 300
flo = rng.normal(0, 30, (F, 3))
P = np.concatenate([np.stack([x,y,z],1), cube, flo]).astype(np.float32)
n = len(P)
col = np.zeros((n,3), np.float32)
col[:N,0] = 0.5+0.5*np.cos(u); col[:N,1] = 0.5+0.5*np.sin(u); col[:N,2] = 0.5+0.5*np.cos(v)
col[N:N+M] = [1.0, 0.85, 0.2]; col[N+M:] = 0.5
SH0 = 0.28209479177387814
f_dc = (col - 0.5)/SH0
opacity = np.full((n,1), 3.0, np.float32)
scale = np.full((n,3), np.log(0.012), np.float32)
rot = np.tile(np.array([1,0,0,0], np.float32), (n,1))
normals = np.zeros((n,3), np.float32); frest = np.zeros((n,45), np.float32)
data = np.concatenate([P, normals, f_dc, frest, opacity, scale, rot], 1).astype('<f4')
props = ['x','y','z','nx','ny','nz','f_dc_0','f_dc_1','f_dc_2'] + [f'f_rest_{i}' for i in range(45)] + ['opacity','scale_0','scale_1','scale_2','rot_0','rot_1','rot_2','rot_3']
hdr = "ply\nformat binary_little_endian 1.0\nelement vertex %d\n" % n + "".join(f"property float {p}\n" for p in props) + "end_header\n"
open(out + "/test_splat.ply", "wb").write(hdr.encode() + data.tobytes())
# --- plain point cloud: xyz + rgb uchar
K = 400000
t = rng.uniform(-3, 3, (K, 2))
pz = 0.3*np.sin(t[:,0]*2)*np.cos(t[:,1]*2)
pts = np.stack([t[:,0], t[:,1], pz], 1).astype('<f4')
rgb = np.stack([(t[:,0]+3)/6*255, (t[:,1]+3)/6*255, (pz+0.3)/0.6*255], 1).clip(0,255).astype(np.uint8)
rec = np.zeros(K, dtype=[('x','<f4'),('y','<f4'),('z','<f4'),('red','u1'),('green','u1'),('blue','u1')])
rec['x'],rec['y'],rec['z'] = pts[:,0],pts[:,1],pts[:,2]; rec['red'],rec['green'],rec['blue'] = rgb[:,0],rgb[:,1],rgb[:,2]
hdr2 = f"ply\nformat binary_little_endian 1.0\nelement vertex {K}\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n"
open(out + "/test_cloud.ply", "wb").write(hdr2.encode() + rec.tobytes())
