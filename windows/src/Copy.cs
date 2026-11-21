// Reads the open Teams chat through UI Automation, maps a copy back to its messages and builds the enriched clipboard.
// Teams' own copy keeps only the message text. Author, time and quotes are read from the UI Automation tree of the
// Teams window, raw view (author-<id>, content-<id>, message-body-<id>; <id> is the arrival time in epoch ms).
// Images are read from the Teams WebView2 HTTP cache. The clipboard gets plain text and HTML with the images embedded.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Automation;
using Forms = System.Windows.Forms;

namespace TeamsSupercopy
{
    public enum PartKind { Text, Quote, Image }

    public class ImageRef
    {
        public string ObjectId;
        public string Alt;
        public Rect Rect;
    }

    public class Part
    {
        public PartKind Kind;
        public string Text;
        public string Author;
        public string Time;
        public ImageRef Image;
    }

    public class Message
    {
        public string Id;
        public DateTime Time;
        public string Author;
        public List<Part> Parts = new List<Part>();
        public string Norm = "";
        public string Chat;
        public Rect Rect = Rect.Empty;
    }

    public class Formatted
    {
        public string Text;
        public string Html;
        public int Count;
        public int Images;
    }

    public static class Copy
    {
        // the pieces the tests replace, as the PowerShell tests replaced the functions
        public static Func<bool> TeamsForeground = DefaultTeamsForeground;
        public static Func<IntPtr, bool> IsTeamsWindow = Native.IsTeamsWindow;
        public static Func<List<Message>> ReadMessages = ReadTeamsMessages;
        public static Action<string, bool> Notice = delegate { };
        public static Action<string> Log = delegate { };
        public static string ImageDir = Path.Combine(Path.GetTempPath(), "teams-supercopy");

        public static Stopwatch HotkeyClock = Stopwatch.StartNew();
        public static List<string> Marks = new List<string>();
        public static uint AutoSequence;
        public static uint PlainClipSeq;

        static readonly Regex QuoteRx = new Regex(@"(?s)(?:Inizio citazione|Begin quote|Start of quote), (.+?), (\d{1,2}/\d{1,2}/\d{2,4},? \d{1,2}[:.]\d{2}(?:\s?[AP]M)?), (.*?), (?:fine citazione|end quote|end of quote)(?:, (?:Questo messaggio citato non è verificato da Teams|This quoted message (?:is not|isn't) verified by Teams)\.?)?\s*");
        static readonly Regex ImageIdRx = new Regex(@"^x_(\d-[a-z]+-d\d+-[0-9a-f]{32})$");
        static readonly Regex NodeIdRx = new Regex(@"^(content|message-body|author-trust-label|author|timestamp)-(\d{10,})$", RegexOptions.IgnoreCase);
        static readonly string TeamsCache = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView");

        static bool DefaultTeamsForeground()
        {
            uint pid;
            Native.GetWindowThreadProcessId(Native.GetForegroundWindow(), out pid);
            try { using (var p = Process.GetProcessById((int)pid)) return p.ProcessName == "ms-teams"; }
            catch { return false; }
        }

        static string Squash(string s) { return Regex.Replace(s ?? "", @"\s+", " ").Trim(); }

        // Process.MainWindowHandle picks any visible Teams window, a toast included, so the
        // window in front is used; otherwise the topmost chat window.
        static IntPtr TeamsWindow()
        {
            IntPtr h = Native.GetForegroundWindow();
            if (IsTeamsWindow(h)) return h;
            var all = Native.TeamsWindows();
            foreach (IntPtr w in all) if (Native.WindowTitle(w).Contains(" | ")) return w;
            if (all.Count > 0) return all[0];
            throw new InvalidOperationException("Teams window not found");
        }

        public static string ChatTitle(string windowTitle)
        {
            // "Chat | <chat name> | <tenant> | <account> | Microsoft Teams"
            string[] parts = Regex.Split(windowTitle, @" \| ");
            return parts.Length >= 3 ? parts[1] : windowTitle;
        }

        public static string Norm(string s)
        {
            return Regex.Replace((s ?? "").ToLowerInvariant(), @"[^\p{L}\p{N}]+", " ").Trim();
        }

        // UIA names a hyperlink "Link <url>"; the clipboard has the bare url, so the label
        // is dropped or a message with a link never matches its own copy.
        public static string RemoveLinkLabel(string s) { return Regex.Replace(s ?? "", @"(?i)\blink\s+(?=https?://)", ""); }

        // Splits message text into an ordered list of text, quote and image parts. A message can quote several
        // messages anywhere in its text; each quote reads "Inizio citazione, <author>, <date>, <text>, fine citazione".
        public static List<Part> SplitParts(string content, List<ImageRef> images)
        {
            var parts = new List<Part>();
            int pos = 0;
            foreach (Match q in QuoteRx.Matches(content))
            {
                if (q.Index > pos) parts.Add(new Part { Kind = PartKind.Text, Text = content.Substring(pos, q.Index - pos).Trim() });
                parts.Add(new Part { Kind = PartKind.Quote, Author = q.Groups[1].Value, Time = q.Groups[2].Value, Text = q.Groups[3].Value.Trim() });
                pos = q.Index + q.Length;
            }
            if (pos < content.Length) parts.Add(new Part { Kind = PartKind.Text, Text = content.Substring(pos).Trim() });

            // the image alt text is part of the content name; put the image where its alt text is
            foreach (ImageRef img in images)
            {
                bool placed = false;
                for (int i = 0; i < parts.Count && !placed; i++)
                {
                    Part p = parts[i];
                    if (p.Kind != PartKind.Text || string.IsNullOrEmpty(img.Alt)) continue;
                    int at = p.Text.IndexOf(img.Alt, StringComparison.Ordinal);
                    if (at < 0) continue;
                    string before = p.Text.Substring(0, at).Trim(), after = p.Text.Substring(at + img.Alt.Length).Trim();
                    parts.RemoveAt(i);
                    var added = new List<Part>();
                    if (before.Length > 0) added.Add(new Part { Kind = PartKind.Text, Text = before });
                    added.Add(new Part { Kind = PartKind.Image, Image = img });
                    if (after.Length > 0) added.Add(new Part { Kind = PartKind.Text, Text = after });
                    parts.InsertRange(i, added);
                    placed = true;
                }
                if (!placed) parts.Insert(0, new Part { Kind = PartKind.Image, Image = img });
            }
            return parts.Where(p => p.Kind != PartKind.Text || !string.IsNullOrEmpty(p.Text)).ToList();
        }

        class RawMessage
        {
            public Dictionary<string, string> Fields = new Dictionary<string, string>();
            public List<string> Labels = new List<string>();
            public List<ImageRef> Images = new List<ImageRef>();
            public Rect Rect = Rect.Empty;
        }

        // Reads every message currently rendered in the chat pane, in display order.
        public static List<Message> ReadTeamsMessages()
        {
            IntPtr win = TeamsWindow();
            string title = Native.WindowTitle(win);
            var cache = new CacheRequest();
            cache.TreeFilter = Automation.RawViewCondition;
            cache.Add(AutomationElement.AutomationIdProperty);
            cache.Add(AutomationElement.NameProperty);
            cache.Add(AutomationElement.BoundingRectangleProperty);
            var listCond = new PropertyCondition(AutomationElement.AutomationIdProperty, "chat-pane-list");
            var nodes = new List<AutomationElement>();
            // the raw view is needed: author-<id> and chat-pane-list are not in the control view
            using (cache.Activate())
            {
                foreach (IntPtr h in Native.RenderWindows(win))
                {
                    AutomationElement list = AutomationElement.FromHandle(h).FindFirst(TreeScope.Descendants, listCond);
                    if (list != null) foreach (AutomationElement e in list.FindAll(TreeScope.Descendants, Condition.TrueCondition)) nodes.Add(e);
                }
            }
            if (nodes.Count == 0) throw new InvalidOperationException("No open chat found in the Teams window");

            var order = new List<string>();
            var byId = new Dictionary<string, RawMessage>();
            string current = null;
            for (int i = 0; i < nodes.Count; i++)
            {
                string aid = nodes[i].Cached.AutomationId ?? "";
                // images sit inside content-<id>, so in document order they follow it
                Match im = ImageIdRx.Match(aid);
                if (im.Success && current != null)
                {
                    byId[current].Images.Add(new ImageRef { ObjectId = im.Groups[1].Value, Alt = Squash(nodes[i].Cached.Name), Rect = nodes[i].Cached.BoundingRectangle });
                    continue;
                }
                Match nm = NodeIdRx.Match(aid);
                if (!nm.Success) continue;
                string kind = nm.Groups[1].Value.ToLowerInvariant(), id = nm.Groups[2].Value;
                if (!byId.ContainsKey(id)) { byId[id] = new RawMessage(); order.Add(id); }
                if (kind == "content") current = id;
                string name = Squash(nodes[i].Cached.Name);
                RawMessage m = byId[id];
                switch (kind)
                {
                    case "author-trust-label": m.Labels.Add(name); break;
                    // the author group has no name of its own; its first child is the name text
                    case "author": if (i + 1 < nodes.Count) m.Fields["author"] = Squash(nodes[i + 1].Cached.Name); break;
                    case "message-body": m.Fields[kind] = name; m.Rect = nodes[i].Cached.BoundingRectangle; break;
                    default: m.Fields[kind] = name; break;
                }
            }

            string chat = ChatTitle(title);
            var result = new List<Message>();
            foreach (string id in order)
            {
                RawMessage m = byId[id];
                if (!m.Fields.ContainsKey("message-body")) continue;
                string content = m.Fields.ContainsKey("content") ? m.Fields["content"] : "";
                content = RemoveLinkLabel(content);
                string author = m.Fields.ContainsKey("author") ? m.Fields["author"] : "";
                if (author.Length == 0)
                {
                    // fallback: message-body = content + author + trust labels + timestamp (+ read
                    // receipt and reactions), so removing the known parts mostly leaves the author
                    author = m.Fields["message-body"];
                    var known = new List<string> { content, m.Fields.ContainsKey("timestamp") ? m.Fields["timestamp"] : "" };
                    known.AddRange(m.Labels);
                    foreach (string part in known) if (!string.IsNullOrEmpty(part)) author = author.Replace(part, " ");
                    author = Squash(author).Trim(' ', '.', ',');
                }
                result.Add(new Message
                {
                    Id = id,
                    Time = DateTimeOffset.FromUnixTimeMilliseconds(long.Parse(id)).LocalDateTime,
                    Author = author,
                    Parts = SplitParts(content, m.Images),
                    Norm = Norm(content),
                    Chat = chat,
                    Rect = m.Rect
                });
            }
            return result;
        }

        static bool ImageOnly(Message m)
        {
            return m.Parts.Count > 0 && m.Parts.All(p => p.Kind == PartKind.Image);
        }

        // Maps the lines Teams put on the clipboard back to the messages they came from.
        // Lines are matched in order; the starting message with the most matched lines wins,
        // so short lines like "ok" do not pull in a match from elsewhere in the chat. On a tie
        // the earliest start wins: a quoting message also contains the quoted text, and the
        // original is the one the selection started from.
        public static List<Message> SelectByClipboardText(List<Message> msgs, string clip, int clipImages)
        {
            var empty = new List<Message>();
            var lines = Regex.Split(clip ?? "", @"\r?\n").Select(l => Norm(l)).Where(l => l.Length >= 2).ToList();
            if (lines.Count == 0 || msgs == null || msgs.Count == 0) return empty;
            List<int> best = null; int bestScore = 0;
            for (int s = 0; s < msgs.Count; s++)
            {
                if (!msgs[s].Norm.Contains(lines[0])) continue;
                var hit = new List<int>();
                int j = s, score = 0;
                foreach (string l in lines)
                {
                    for (int k = j; k < Math.Min(msgs.Count, j + 4); k++)
                    {
                        if (msgs[k].Norm.Contains(l)) { score++; j = k; if (!hit.Contains(k)) hit.Add(k); break; }
                    }
                }
                if (score > bestScore) { best = hit; bestScore = score; }
            }
            if (bestScore == 0) return empty;
            // a selection is contiguous: messages skipped between matched ones are kept. An
            // image-only message has no text line on the clipboard (Teams puts its image only
            // in the HTML), so the range grows by image-only neighbours while the copy holds
            // images the range does not account for.
            int lo = best.Min(), hi = best.Max();
            int missing = clipImages;
            for (int k = lo; k <= hi; k++) missing -= msgs[k].Parts.Count(p => p.Kind == PartKind.Image);
            while (missing > 0 && hi + 1 < msgs.Count && ImageOnly(msgs[hi + 1])) { hi++; missing -= msgs[hi].Parts.Count; }
            while (missing > 0 && lo > 0 && ImageOnly(msgs[lo - 1])) { lo--; missing -= msgs[lo].Parts.Count; }
            return msgs.GetRange(lo, hi - lo + 1);
        }

        // UIA FromPoint on the Teams webview returns the whole message pane, not the bubble,
        // so the hovered message is found by geometry: the bubble that contains the cursor,
        // or else the one nearest to it vertically (cursor in the margin beside a bubble).
        public static List<Message> SelectHovered(List<Message> msgs)
        {
            Native.POINT p;
            Native.GetCursorPos(out p);
            var visible = msgs.Where(m => !m.Rect.IsEmpty && m.Rect.Height > 0).ToList();
            Message hit = visible.FirstOrDefault(m => m.Rect.Contains(p.X, p.Y));
            if (hit == null) hit = visible.FirstOrDefault(m => p.Y >= m.Rect.Top && p.Y <= m.Rect.Bottom);
            return hit == null ? new List<Message>() : new List<Message> { hit };
        }

        static byte[] ReadShared(string path)
        {
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var ms = new MemoryStream()) { fs.CopyTo(ms); return ms.ToArray(); }
        }

        // extension and MIME type from the first bytes, or null when the bytes are not an image
        public static string[] ImageType(byte[] b)
        {
            if (b == null || b.Length < 12) return null;
            if (b[0] == 0xFF && b[1] == 0xD8) return new[] { "jpg", "image/jpeg" };
            if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return new[] { "png", "image/png" };
            if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return new[] { "gif", "image/gif" };
            if (b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) return new[] { "webp", "image/webp" };
            return null;
        }

        // Teams downloads images through its WebView2, so the full image is in the Chromium
        // HTTP cache (blockfile format) under a key ending in objects/<objectId>/views/<view>.
        // Entries are 256-byte blocks in data_1: key_len at +32, data_size[4] at +40,
        // data_addr[4] at +56, key at +96; stream 1 is the body.
        static List<string> cacheDirs;
        public static byte[] CachedImage(string objectId)
        {
            // resolving the folders costs ~150 ms, so they are looked up once
            if (cacheDirs == null)
            {
                cacheDirs = new List<string>();
                if (Directory.Exists(TeamsCache))
                    foreach (string d in Directory.GetDirectories(TeamsCache))
                    {
                        string data = Path.Combine(d, @"Cache\Cache_Data");
                        if (File.Exists(Path.Combine(data, "data_1"))) cacheDirs.Add(data);
                    }
            }
            foreach (string dir in cacheDirs.ToList())
            {
                string idx = Path.Combine(dir, "data_1");
                if (!File.Exists(idx)) { cacheDirs = null; continue; }
                byte[] d1 = ReadShared(idx);
                string s = Encoding.ASCII.GetString(d1);
                string key = "objects/" + objectId + "/views/";
                var hits = new List<int>();
                for (int i = s.IndexOf(key, StringComparison.Ordinal); i >= 0; i = s.IndexOf(key, i + 1, StringComparison.Ordinal)) hits.Add(i);
                // original first, then the largest previews
                hits = hits.OrderBy(h =>
                {
                    string v = s.Substring(h + key.Length, Math.Min(20, s.Length - h - key.Length));
                    return v.StartsWith("imgo", StringComparison.Ordinal) ? 0 : v.StartsWith("imgpsh_fullsize", StringComparison.Ordinal) ? 1 : 2;
                }).ToList();
                foreach (int hit in hits)
                {
                    int entry = 8192 + (hit - 8192) / 256 * 256;
                    while (entry > 8192 && !Regex.IsMatch(s.Substring(entry + 96, 4), "^(1/0/|http|_dk_)")) entry -= 256;
                    int size = BitConverter.ToInt32(d1, entry + 44);
                    uint addr = BitConverter.ToUInt32(d1, entry + 60);
                    if (size <= 0 || (addr & 0x80000000) == 0) continue;
                    uint type = (addr >> 28) & 7;
                    byte[] b;
                    try
                    {
                        if (type == 0) b = ReadShared(Path.Combine(dir, string.Format("f_{0:x6}", addr & 0x0FFFFFFF)));
                        else
                        {
                            // block files run to several MB; read only the entry's bytes
                            int blockSize = type == 2 ? 256 : type == 3 ? 1024 : type == 4 ? 4096 : 0;
                            if (blockSize == 0) continue;
                            using (var fs = new FileStream(Path.Combine(dir, string.Format("data_{0}", (addr >> 16) & 0xFF)), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                            {
                                fs.Seek(8192 + (long)(addr & 0xFFFF) * blockSize, SeekOrigin.Begin);
                                b = new byte[size];
                                int got = 0;
                                while (got < size) { int r = fs.Read(b, got, size - got); if (r <= 0) break; got += r; }
                            }
                        }
                    }
                    catch { continue; }
                    if (b.Length > size) Array.Resize(ref b, size);
                    if (ImageType(b) != null) return b;
                }
            }
            return null;
        }

        // Fallback for an image that is not in the cache: grab what is on screen, which is
        // the thumbnail size Teams shows in the chat.
        static byte[] ScreenImage(Rect rect)
        {
            if (rect.IsEmpty || rect.Width < 8 || rect.Height < 8) return null;
            using (var bmp = new System.Drawing.Bitmap((int)rect.Width, (int)rect.Height))
            using (var g = System.Drawing.Graphics.FromImage(bmp))
            using (var ms = new MemoryStream())
            {
                g.CopyFromScreen((int)rect.X, (int)rect.Y, 0, 0, bmp.Size);
                bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                return ms.ToArray();
            }
        }

        class SavedImage { public string Path; public string Mime; public byte[] Bytes; public string Source; }

        static SavedImage SaveImage(ImageRef img)
        {
            byte[] bytes = CachedImage(img.ObjectId);
            string source = "original";
            if (bytes == null) { bytes = ScreenImage(img.Rect); source = "screen thumbnail"; }
            string[] t = ImageType(bytes);
            if (t == null) return null;
            Directory.CreateDirectory(ImageDir);
            string path = Path.Combine(ImageDir, img.ObjectId + "." + t[0]);
            File.WriteAllBytes(path, bytes);
            return new SavedImage { Path = path, Mime = t[1], Bytes = bytes, Source = source };
        }

        static string Enc(string s) { return WebUtility.HtmlEncode(s); }

        // Builds the same content twice: plain text (images as [image N] plus the saved
        // file path) and HTML with the images embedded, which chat apps such as claude.ai
        // paste as text plus image attachments in one go.
        public static Formatted Format(List<Message> msgs)
        {
            if (msgs == null || msgs.Count == 0) return null;
            try
            {
                if (Directory.Exists(ImageDir))
                    foreach (string f in Directory.GetFiles(ImageDir))
                        if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-1)) try { File.Delete(f); } catch { }
            }
            catch { }
            var txt = new StringBuilder();
            var html = new StringBuilder();
            int n = 0;
            txt.AppendLine("Teams chat: " + msgs[0].Chat).AppendLine();
            html.Append("<p><b>Teams chat: " + Enc(msgs[0].Chat) + "</b></p>");
            foreach (Message m in msgs)
            {
                string head = string.Format("[{0:yyyy-MM-dd HH:mm}] {1}", m.Time, m.Author);
                txt.AppendLine(head);
                html.Append("<p><b>" + Enc(head) + "</b>");
                if (m.Parts.Count == 0)
                {
                    txt.AppendLine("(no text: attachment or card)");
                    html.Append("<br>(no text: attachment or card)");
                }
                foreach (Part p in m.Parts)
                {
                    switch (p.Kind)
                    {
                        case PartKind.Text:
                            txt.AppendLine(p.Text);
                            html.Append("<br>" + Enc(p.Text));
                            break;
                        case PartKind.Quote:
                            string q = string.Format("> in reply to {0} ({1}): {2}", p.Author, p.Time, p.Text);
                            txt.AppendLine(q);
                            html.Append("<br>" + Enc(q));
                            break;
                        case PartKind.Image:
                            n++;
                            SavedImage saved = p.Image == null ? null : SaveImage(p.Image);
                            if (saved != null)
                            {
                                txt.AppendLine(string.Format("[image {0}: {1}, {2}]", n, saved.Source, saved.Path));
                                html.Append(string.Format("<br>[image {0}]<br><img alt=\"\" src=\"data:{1};base64,{2}\">", n, saved.Mime, Convert.ToBase64String(saved.Bytes)));
                            }
                            else
                            {
                                txt.AppendLine(string.Format("[image {0}: not available, scroll it into view and copy again]", n));
                                html.Append(string.Format("<br>[image {0}: not available]", n));
                            }
                            break;
                    }
                }
                txt.AppendLine();
                html.Append("</p>");
            }
            return new Formatted { Text = txt.ToString().TrimEnd() + Environment.NewLine, Html = html.ToString(), Count = msgs.Count, Images = n };
        }

        public static byte[] CfHtml(string fragment)
        {
            const string pre = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";
            const string head = "<html><body><!--StartFragment-->", tail = "<!--EndFragment--></body></html>";
            Encoding u = Encoding.UTF8;
            int sh = u.GetByteCount(string.Format(pre, 0, 0, 0, 0));
            int sf = sh + u.GetByteCount(head);
            int ef = sf + u.GetByteCount(fragment);
            int eh = ef + u.GetByteCount(tail);
            return u.GetBytes(string.Format(pre, sh, eh, sf, ef) + head + fragment + tail);
        }

        public static void OutResult(Formatted r, string mode)
        {
            if (r == null)
            {
                Log(mode + " -> no matching message");
                // an automatic pass on a copy that is not messages (text from the compose box,
                // a link, an image) leaves Teams' copy alone without complaining
                if (mode == "Auto") return;
                System.Media.SystemSounds.Asterisk.Play();
                Notice(mode == "Hover" ? "Teams Supercopy: no message under the mouse" : "Teams Supercopy: selection not matched, clipboard left as Teams copied it", false);
                return;
            }
            string what = string.Format("{0} message{1}", r.Count, r.Count != 1 ? "s" : "");
            if (r.Images > 0) what += string.Format(", {0} image{1}", r.Images, r.Images != 1 ? "s" : "");
            var d = new Forms.DataObject();
            d.SetData(Forms.DataFormats.UnicodeText, r.Text);
            d.SetData(Forms.DataFormats.Html, new MemoryStream(CfHtml(r.Html)));
            if (mode == "Auto" && (AutoSequence != Native.GetClipboardSequenceNumber() || !TeamsForeground() || (Native.GetAsyncKeyState(0x10) & 0x8000) != 0))
            {
                Log("Auto skipped: clipboard, foreground or Shift changed");
                return;
            }
            Forms.Clipboard.SetDataObject(d, true);
            Log(string.Format("{0} -> {1} ({2} ms from hotkey to clipboard; {3})", mode, what, HotkeyClock.ElapsedMilliseconds, string.Join(", ", Marks)));
            Notice("Teams Supercopy: " + what + " copied", true);
        }

        public static void Invoke(string mode)
        {
            switch (mode)
            {
                case "All": OutResult(Format(ReadMessages()), mode); break;
                case "Hover": OutResult(Format(SelectHovered(ReadMessages())), mode); break;
                default:
                    string clip = Forms.Clipboard.GetText();
                    object htmlData = Forms.Clipboard.GetData("HTML Format");
                    string clipHtml = htmlData == null ? "" : htmlData.ToString();
                    int clipImages = Regex.Matches(clipHtml, "itemtype=\"http://schema\\.skype\\.com/AMSImage\"").Count;
                    Marks.Add("text read " + HotkeyClock.ElapsedMilliseconds);
                    List<Message> msgs = ReadMessages();
                    Marks.Add("chat read " + HotkeyClock.ElapsedMilliseconds);
                    OutResult(Format(SelectByClipboardText(msgs, clip, clipImages)), mode);
                    break;
            }
        }

        // A copy made inside Teams carries the page URL in a Chromium clipboard format;
        // the special copy written here does not, so it never re-triggers itself.
        public static bool IsTeamsClipboard()
        {
            try
            {
                if (!TeamsForeground()) return false;
                IntPtr window = Native.EventForeground;
                if (!IsTeamsWindow(window) || !Native.OwnerBelongsToWindow(Native.EventOwnerRoot, window))
                {
                    Log(string.Format("Auto ignored: source window mismatch (foreground={0}, owner={1})", window, Native.EventOwnerRoot));
                    return false;
                }
                // EverTranscript writes plain text. Only native rich message copies qualify.
                if (!Forms.Clipboard.ContainsData("HTML Format")) return false;
                object u = Forms.Clipboard.GetData("Chromium internal source URL");
                string url = u is MemoryStream ? Encoding.UTF8.GetString(((MemoryStream)u).ToArray()).Trim('\0') : (u == null ? "" : u.ToString());
                return Regex.IsMatch(url, @"^https://teams\.(microsoft\.com|cloud\.microsoft|live\.com)/", RegexOptions.IgnoreCase);
            }
            catch { return false; }
        }

        public static bool IsPlainCopyEvent(uint sequence)
        {
            return sequence == PlainClipSeq || Native.EventShift || (Native.GetAsyncKeyState(0x10) & 0x8000) != 0;
        }
    }
}
