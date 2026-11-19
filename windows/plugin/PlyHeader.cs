using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace QuickLook.Plugin.SplatViewer
{
    internal enum PlyKind { Unknown, Splat, Points, Mesh }

    internal sealed class PlyInfo
    {
        public PlyKind Kind = PlyKind.Unknown;
        public long VertexCount = -1;
        public int ShDegree = -1;                // -1 = unknown / not a splat
        public List<string> Comments = new List<string>();
    }

    /// <summary>
    /// Reads only the .ply header (a few KB) to tell Gaussian splats, point clouds and meshes apart.
    /// </summary>
    internal static class PlyHeader
    {
        public static PlyInfo Read(string path)
        {
            var info = new PlyInfo();
            string header;
            try
            {
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var buf = new byte[65536];
                    var n = fs.Read(buf, 0, buf.Length);
                    header = Encoding.UTF8.GetString(buf, 0, n);
                }
            }
            catch
            {
                return info;
            }

            if (!header.StartsWith("ply")) return info;
            var end = header.IndexOf("end_header", StringComparison.Ordinal);
            if (end < 0) return info;

            var elements = new Dictionary<string, long>();
            var vertexProps = new HashSet<string>();
            string current = null;

            foreach (var raw in header.Substring(0, end).Split('\n'))
            {
                var line = raw.Trim();
                if (line.StartsWith("comment ") || line.StartsWith("obj_info "))
                {
                    var c = line.Substring(line.IndexOf(' ') + 1).Trim();
                    if (c.Length > 0 && info.Comments.Count < 8) info.Comments.Add(c);
                    continue;
                }
                var t = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (t.Length == 0) continue;
                if (t[0] == "element" && t.Length >= 3)
                {
                    current = t[1];
                    long.TryParse(t[2], out var count);
                    elements[current] = count;
                }
                else if (t[0] == "property" && current == "vertex")
                {
                    vertexProps.Add(t[t.Length - 1]);
                }
            }

            if (elements.TryGetValue("vertex", out var vc)) info.VertexCount = vc;

            var fRest = vertexProps.Count(p => p.StartsWith("f_rest_"));
            var shDegree = fRest >= 45 ? 3 : fRest >= 24 ? 2 : fRest >= 9 ? 1 : 0;

            if (elements.ContainsKey("chunk") || vertexProps.Contains("packed_position"))
            {
                // PlayCanvas / SuperSplat compressed PLY (SH stored in a separate element)
                info.Kind = PlyKind.Splat;
                if (elements.TryGetValue("sh", out _)) info.ShDegree = -1; else info.ShDegree = 0;
            }
            else if (vertexProps.Contains("f_dc_0") ||
                     (vertexProps.Contains("scale_0") && vertexProps.Contains("rot_0") && vertexProps.Contains("opacity")))
            {
                info.Kind = PlyKind.Splat;
                info.ShDegree = shDegree;
            }
            else if (elements.TryGetValue("face", out var faces) && faces > 0)
                info.Kind = PlyKind.Mesh;
            else if (vertexProps.Contains("x") && vertexProps.Contains("y") && vertexProps.Contains("z"))
                info.Kind = PlyKind.Points;

            return info;
        }
    }
}
