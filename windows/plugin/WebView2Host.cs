using System;
using System.IO;
using System.Linq;
using System.Linq.Expressions;
using System.Reflection;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace QuickLook.Plugin.QuickSplat
{
    /// <summary>
    /// One WebView2 + viewer page shared by all previews: it's created on the first preview and then
    /// reused, so the browser process start and the page/WASM init are paid only once.
    /// WebView2 is used via reflection from the copy QuickLook ships with its HtmlViewer.
    /// </summary>
    internal sealed class WebView2Host
    {
        public const string AppHost = "sqv-app.local";
        public const string FileHost = "sqv-file.local";
        private static readonly TimeSpan IdleDispose = TimeSpan.FromMinutes(10);

        private static Assembly _wpf;
        private static Assembly _core;
        private static WebView2Host _shared;

        private object _webView;                 // Microsoft.Web.WebView2.Wpf.WebView2
        private object _coreWebView;             // CoreWebView2
        private Task _ready;                     // init + first navigation completed
        private readonly System.Collections.Generic.Dictionary<string, string> _rootHosts =
            new System.Collections.Generic.Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private TaskCompletionSource<bool> _navDone;
        private DispatcherTimer _idleTimer;
        private bool _disposed;
        private int _generation;                 // bumped on every Release(), cancels stale opens

        public object Control => _webView;

        // ---------- assemblies ----------
        public static bool TryLoadAssemblies(string pluginDir, out string error)
        {
            error = null;
            if (_wpf != null && _core != null) return true;
            try
            {
                _wpf = FindLoaded("Microsoft.Web.WebView2.Wpf");
                if (_wpf == null)
                {
                    var path = FindFile(pluginDir, "Microsoft.Web.WebView2.Wpf.dll");
                    if (path == null)
                    {
                        error = "Microsoft.Web.WebView2.Wpf.dll not found (it normally ships with QuickLook's HtmlViewer plugin).";
                        return false;
                    }
                    _wpf = Assembly.LoadFrom(path);
                }

                _core = FindLoaded("Microsoft.Web.WebView2.Core");
                if (_core == null)
                {
                    var corePath = Path.Combine(Path.GetDirectoryName(_wpf.Location) ?? "", "Microsoft.Web.WebView2.Core.dll");
                    if (!File.Exists(corePath)) corePath = FindFile(pluginDir, "Microsoft.Web.WebView2.Core.dll");
                    if (corePath == null)
                    {
                        error = "Microsoft.Web.WebView2.Core.dll not found.";
                        return false;
                    }
                    _core = Assembly.LoadFrom(corePath);
                }
                return true;
            }
            catch (Exception ex)
            {
                error = "Failed to load WebView2: " + ex.Message;
                _wpf = _core = null;
                return false;
            }
        }

        private static Assembly FindLoaded(string name) =>
            AppDomain.CurrentDomain.GetAssemblies()
                .FirstOrDefault(a => string.Equals(a.GetName().Name, name, StringComparison.OrdinalIgnoreCase));

        private static string FindFile(string pluginDir, string fileName)
        {
            var p = Path.Combine(pluginDir, fileName);
            if (File.Exists(p)) return p;

            var baseDir = AppDomain.CurrentDomain.BaseDirectory;
            p = Path.Combine(baseDir, "QuickLook.Plugin", "QuickLook.Plugin.HtmlViewer", fileName);
            if (File.Exists(p)) return p;

            try { return Directory.GetFiles(baseDir, fileName, SearchOption.AllDirectories).FirstOrDefault(); }
            catch { return null; }
        }

        // ---------- shared instance ----------
        public static WebView2Host GetShared(string userDataFolder, string webDir)
        {
            if (_shared == null || _shared._disposed)
                _shared = new WebView2Host(userDataFolder, webDir);
            _shared.StopIdleTimer();
            return _shared;
        }

        private WebView2Host(string userDataFolder, string webDir)
        {
            var wvType = _wpf.GetType("Microsoft.Web.WebView2.Wpf.WebView2", true);
            var propsType = _wpf.GetType("Microsoft.Web.WebView2.Wpf.CoreWebView2CreationProperties", true);

            var props = Activator.CreateInstance(propsType);
            SetProp(props, "UserDataFolder", userDataFolder);

            _webView = Activator.CreateInstance(wvType);
            SetProp(_webView, "CreationProperties", props);
            SetProp(_webView, "DefaultBackgroundColor", System.Drawing.Color.FromArgb(255, 30, 30, 30));

            _ready = InitAsync(webDir);
        }

        private async Task InitAsync(string webDir)
        {
            var wvType = _webView.GetType();
            var ensure = wvType.GetMethods()
                .Where(m => m.Name == "EnsureCoreWebView2Async")
                .OrderBy(m => m.GetParameters().Length)
                .First();
            await (Task)ensure.Invoke(_webView, ensure.GetParameters().Select(_ => (object)null).ToArray());

            _coreWebView = wvType.GetProperty("CoreWebView2").GetValue(_webView);

            var settings = _coreWebView.GetType().GetProperty("Settings")?.GetValue(_coreWebView);
            if (settings != null)
            {
                SetProp(settings, "AreDefaultContextMenusEnabled", false);
                SetProp(settings, "IsStatusBarEnabled", false);
                SetProp(settings, "IsZoomControlEnabled", false);
            }

            MapFolder(AppHost, webDir);

            // WebView2 applies folder mappings only to pages loaded AFTER the mapping is set,
            // so every drive is mapped up front (one virtual host per drive) and never remapped.
            foreach (var drive in Directory.GetLogicalDrives())
                TryMapRoot(drive);

            Subscribe(_coreWebView, "NavigationCompleted", e =>
            {
                var ok = e.GetType().GetProperty("IsSuccess")?.GetValue(e) as bool? ?? true;
                _navDone?.TrySetResult(ok);
            });
            await NavigateAsync();
        }

        private async Task NavigateAsync()
        {
            _navDone = new TaskCompletionSource<bool>();
            var url = "https://" + AppHost + "/index.html";
            var current = _webView.GetType().GetProperty("Source")?.GetValue(_webView) as Uri;
            if (current != null && current.AbsoluteUri.StartsWith(url))
                _coreWebView.GetType().GetMethod("Reload")?.Invoke(_coreWebView, null);
            else
                SetProp(_webView, "Source", new Uri(url));
            if (!await _navDone.Task) throw new Exception("The viewer page failed to load.");
        }

        private string TryMapRoot(string root)
        {
            if (_rootHosts.TryGetValue(root, out var existing)) return existing;
            string host;
            if (root.Length >= 2 && root[1] == ':' && char.IsLetter(root[0]))
                host = char.ToLowerInvariant(root[0]) + "." + FileHost;           // C:\ -> c.sqv-file.local
            else
                host = "r" + ((uint)root.ToLowerInvariant().GetHashCode()).ToString("x8") + "." + FileHost; // UNC share
            try
            {
                MapFolder(host, root);
                _rootHosts[root] = host;
                return host;
            }
            catch
            {
                return null;   // e.g. empty card reader
            }
        }

        /// <summary>Opens a file in the (already loaded) viewer page.</summary>
        public async Task OpenAsync(string filePath, string infoJsonWithoutSrc, string srcQuery)
        {
            var gen = ++_generation;
            await _ready;
            if (_disposed || gen != _generation) return;

            var full = Path.GetFullPath(filePath);
            var root = Path.GetPathRoot(full);
            if (!_rootHosts.ContainsKey(root))
            {
                // new drive / network share since the page was loaded: map it and reload the page
                if (TryMapRoot(root) == null) throw new Exception("Can't access " + root);
                await NavigateAsync();
                if (_disposed || gen != _generation) return;
            }
            var host = _rootHosts[root];
            var rel = full.Substring(root.Length).TrimStart('\\', '/');
            var src = "https://" + host + "/" +
                      string.Join("/", rel.Split('\\', '/').Select(Uri.EscapeDataString)) + srcQuery;
            var json = "{\"src\":" + Json.Str(src) + "," + infoJsonWithoutSrc + "}";
            await ExecuteScriptAsync("window.sqvOpen(" + json + ")");
        }

        /// <summary>Preview closed: free the splat from GPU memory, keep the page alive for the next one.</summary>
        public void Release()
        {
            if (_disposed) return;
            _generation++;
            if (_coreWebView != null)
            {
                try { _ = ExecuteScriptAsync("window.sqvClear && window.sqvClear()"); } catch { /* ignore */ }
            }
            StartIdleTimer();
        }

        private Task ExecuteScriptAsync(string script)
        {
            var m = _coreWebView.GetType().GetMethod("ExecuteScriptAsync", new[] { typeof(string) });
            return (Task)m.Invoke(_coreWebView, new object[] { script });
        }

        private void MapFolder(string host, string folder)
        {
            var kindType = _core.GetType("Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind", true);
            var allow = Enum.Parse(kindType, "Allow");
            _coreWebView.GetType().GetMethod("SetVirtualHostNameToFolderMapping")
                .Invoke(_coreWebView, new object[] { host, folder, allow });
        }


        // after a while without previews, close the browser process to give back its memory
        private void StartIdleTimer()
        {
            if (_idleTimer == null)
            {
                _idleTimer = new DispatcherTimer { Interval = IdleDispose };
                _idleTimer.Tick += (s, e) => Dispose();
            }
            _idleTimer.Stop();
            _idleTimer.Start();
        }

        private void StopIdleTimer() => _idleTimer?.Stop();

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _idleTimer?.Stop();
            try { (_webView as IDisposable)?.Dispose(); } catch { /* ignore */ }
            _webView = null;
            _coreWebView = null;
            if (ReferenceEquals(_shared, this)) _shared = null;
        }

        // ---------- reflection helpers ----------
        private static void SetProp(object target, string name, object value)
        {
            var pi = target.GetType().GetProperty(name);
            if (pi != null && pi.CanWrite) pi.SetValue(target, value);
        }

        /// <summary>Subscribes to an EventHandler&lt;T&gt; event without knowing T at compile time.</summary>
        private static void Subscribe(object target, string eventName, Action<object> handler)
        {
            var ev = target.GetType().GetEvent(eventName);
            var ps = ev.EventHandlerType.GetMethod("Invoke").GetParameters();
            var sender = Expression.Parameter(ps[0].ParameterType, "s");
            var args = Expression.Parameter(ps[1].ParameterType, "e");
            var body = Expression.Invoke(Expression.Constant(handler), Expression.Convert(args, typeof(object)));
            ev.AddEventHandler(target, Expression.Lambda(ev.EventHandlerType, body, sender, args).Compile());
        }
    }

    internal static class Json
    {
        public static string Str(string s)
        {
            if (s == null) return "null";
            var sb = new System.Text.StringBuilder("\"");
            foreach (var c in s)
            {
                switch (c)
                {
                    case '"': sb.Append("\\\""); break;
                    case '\\': sb.Append("\\\\"); break;
                    case '\n': sb.Append("\\n"); break;
                    case '\r': sb.Append("\\r"); break;
                    case '\t': sb.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c == (char)0x2028 || c == (char)0x2029) sb.AppendFormat("\\u{0:x4}", (int)c);
                        else sb.Append(c);
                        break;
                }
            }
            return sb.Append('"').ToString();
        }
    }
}
