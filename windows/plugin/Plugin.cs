using QuickLook.Common.Plugin;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Windows;

namespace QuickLook.Plugin.QuickSplat
{
    public sealed class Plugin : IViewer
    {
        // extensions that are always splats
        private static readonly string[] SplatExtensions = { ".splat", ".ksplat", ".spz", ".sog" };

        private WebView2Host _host;

        // above QuickLook's HelixViewer (-5), which also claims .ply
        public int Priority => 10;

        public void Init()
        {
        }

        public bool CanHandle(string path)
        {
            if (Directory.Exists(path)) return false;
            return Detect(path, out _) != null;
        }

        /// <summary>"splat" | "points" | null (mesh .ply files are left to HelixViewer)</summary>
        private static string Detect(string path, out PlyInfo ply)
        {
            ply = null;
            var ext = Path.GetExtension(path).ToLowerInvariant();
            if (SplatExtensions.Contains(ext)) return "splat";
            if (ext != ".ply") return null;

            ply = PlyHeader.Read(path);
            switch (ply.Kind)
            {
                case PlyKind.Splat: return "splat";
                case PlyKind.Points: return "points";
                default: return null;
            }
        }

        public void Prepare(string path, ContextObject context)
        {
            context.PreferredSize = new Size { Width = 1200, Height = 800 };
            context.Theme = Themes.Dark;
        }

        public async void View(string path, ContextObject context)
        {
            context.Title = Path.GetFileName(path);

            var pluginDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? "";
            var webDir = Path.Combine(pluginDir, "web");

            if (!WebView2Host.TryLoadAssemblies(pluginDir, out var error))
            {
                ShowMessage(context, error);
                return;
            }

            try
            {
                var udf = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "QuickLook.Plugin.QuickSplat", "WebView2");

                _host = WebView2Host.GetShared(udf, webDir);
                context.ViewerContent = _host.Control;

                var fi = new FileInfo(path);
                var kind = Detect(path, out var ply) ?? "splat";
                // ?v=<mtime> so an edited file is never served from cache
                var srcQuery = "?v=" + fi.LastWriteTimeUtc.Ticks;

                await _host.OpenAsync(path, BuildInfoJson(fi, kind, ply), srcQuery);
                context.IsBusy = false;
            }
            catch (Exception ex)
            {
                var inner = ex is TargetInvocationException tie && tie.InnerException != null ? tie.InnerException : ex;
                _host?.Dispose();   // start clean on the next preview
                _host = null;
                var msg = inner.GetType().Name.Contains("RuntimeNotFound")
                    ? "The Microsoft Edge WebView2 Runtime is missing.\nGet it from https://go.microsoft.com/fwlink/p/?LinkId=2124703"
                    : "Error: " + inner.Message;
                ShowMessage(context, msg);
            }
        }

        private static string BuildInfoJson(FileInfo fi, string kind, PlyInfo ply)
        {
            var parts = new List<string>
            {
                "\"kind\":" + Json.Str(kind),
                "\"name\":" + Json.Str(fi.Name),
                "\"path\":" + Json.Str(fi.FullName),
                "\"size\":" + fi.Length,
                "\"created\":" + Json.Str(fi.CreationTime.ToString("o")),
                "\"modified\":" + Json.Str(fi.LastWriteTime.ToString("o")),
            };
            if (ply != null)
            {
                if (ply.ShDegree >= 0) parts.Add("\"shDegree\":" + ply.ShDegree);
                if (ply.VertexCount >= 0) parts.Add("\"vertexCount\":" + ply.VertexCount);
                if (ply.Comments.Count > 0)
                {
                    parts.Add("\"comment\":" + Json.Str(ply.Comments[0]));
                    parts.Add("\"comments\":[" + string.Join(",", ply.Comments.Select(Json.Str)) + "]");
                }
            }
            return string.Join(",", parts);
        }

        private static void ShowMessage(ContextObject context, string text)
        {
            // TextBlock created via reflection (no compile-time reference to PresentationFramework)
            var tbType = Type.GetType("System.Windows.Controls.TextBlock, PresentationFramework, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
            if (tbType != null)
            {
                var tb = Activator.CreateInstance(tbType);
                tbType.GetProperty("Text").SetValue(tb, text);
                SetEnum(tb, "TextWrapping", "Wrap");
                SetEnum(tb, "HorizontalAlignment", "Center");
                SetEnum(tb, "VerticalAlignment", "Center");
                var marginProp = tbType.GetProperty("Margin");
                marginProp.SetValue(tb, Activator.CreateInstance(marginProp.PropertyType, 24.0));
                context.ViewerContent = tb;
            }
            context.IsBusy = false;
        }

        private static void SetEnum(object target, string prop, string value)
        {
            var pi = target.GetType().GetProperty(prop);
            pi.SetValue(target, Enum.Parse(pi.PropertyType, value));
        }

        public void Cleanup()
        {
            // keep the shared WebView2 alive, just unload the splat
            _host?.Release();
            _host = null;
        }
    }
}
