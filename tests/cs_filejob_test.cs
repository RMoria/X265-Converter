using System;
using System.ComponentModel;
using System.Windows.Threading;

namespace System.Windows.Threading {
  public class Dispatcher {
    public bool CheckAccess(){ return true; }
    public object BeginInvoke(System.Delegate d){ return null; }
  }
}

namespace X265
{
    public class FileJob : INotifyPropertyChanged
    {
        private Dispatcher _disp;

        public FileJob() { }
        public FileJob(Dispatcher d) { _disp = d; }

        public event PropertyChangedEventHandler PropertyChanged;

        private void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h == null) return;
            PropertyChangedEventArgs a = new PropertyChangedEventArgs(name);
            if (_disp != null && !_disp.CheckAccess())
                _disp.BeginInvoke((Action)(() => h(this, a)));
            else
                h(this, a);
        }

        // ---- gebonden aan de DataGrid -----------------------------
        // Al-HEVC-regels mogen niet worden aangevinkt. De setter weigert
        // dat hard, zodat geen enkele weg eromheen leidt.
        private bool _include = true;
        public bool Include
        {
            get { return _include; }
            set
            {
                bool v = value;
                if (v && _isHevc) { v = false; }
                if (_include == v) { return; }
                _include = v;
                Raise("Include");
            }
        }

        private string _name = "";
        public string Name { get { return _name; } set { _name = value; Raise("Name"); } }

        private string _folder = "";
        public string Folder { get { return _folder; } set { _folder = value; Raise("Folder"); } }

        private string _codec = "";
        public string Codec { get { return _codec; } set { _codec = value; Raise("Codec"); } }

        private string _sizeText = "";
        public string SizeText { get { return _sizeText; } set { _sizeText = value; Raise("SizeText"); } }

        private string _durationText = "";
        public string DurationText { get { return _durationText; } set { _durationText = value; Raise("DurationText"); } }

        private string _status = "In wachtrij";
        public string Status { get { return _status; } set { _status = value; Raise("Status"); } }

        private string _resultText = "";
        public string ResultText { get { return _resultText; } set { _resultText = value; Raise("ResultText"); } }

        private string _newSizeText = "";
        public string NewSizeText { get { return _newSizeText; } set { _newSizeText = value; Raise("NewSizeText"); } }

        // Positie in de wachtrij, als drie cijfers met voorloopnullen.
        // Leeg wanneer de regel niet in de wachtrij staat.
        private string _queueText = "";
        public string QueueText { get { return _queueText; } set { _queueText = value; Raise("QueueText"); } }

        // Al HEVC? Dan is aanvinken uitgesloten en is het vinkje grijs.
        private bool _isHevc = false;
        public bool IsHevc
        {
            get { return _isHevc; }
            set
            {
                if (_isHevc == value) { return; }
                _isHevc = value;
                if (_isHevc && _include) { _include = false; Raise("Include"); }
                Raise("IsHevc");
                Raise("CanInclude");
            }
        }

        /// <summary>Onwaar voor al-HEVC-regels; hieraan hangt IsEnabled van het vinkje.</summary>
        public bool CanInclude { get { return !_isHevc; } }

        // ---- niet gebonden, alleen data ---------------------------
        public string FullPath   { get; set; }
        public long   SizeBytes  { get; set; }
        public long   NewBytes   { get; set; }
        public double DurationSec{ get; set; }
        public bool   Queued     { get; set; }
        public int    QueuePos   { get; set; }
        public double EncodeSec  { get; set; }
        public string RawCodec   { get; set; }
    }
}