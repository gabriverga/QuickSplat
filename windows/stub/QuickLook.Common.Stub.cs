// REFERENCE-ONLY assembly used to compile the plugin outside Windows.
// It mirrors the names and signatures of the QuickLook.Common types the plugin uses.
// It is never shipped: at runtime QuickLook loads its real QuickLook.Common.dll.
using System.ComponentModel;
using System.Windows;

[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

namespace QuickLook.Common.Plugin
{
    public enum Themes { None, Dark, Light }

    public interface IViewer
    {
        int Priority { get; }
        void Init();
        bool CanHandle(string path);
        void Prepare(string path, ContextObject context);
        void View(string path, ContextObject context);
        void Cleanup();
    }

    public class ContextObject : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        public object Source { get; set; }
        public string Title { get; set; }
        public object ViewerContent { get; set; }
        public bool IsBusy { get; set; }
        public Size PreferredSize { get; set; }
        public bool CanResize { get; set; }
        public bool FullWindowDragging { get; set; }
        public Themes Theme { get; set; }
    }
}
