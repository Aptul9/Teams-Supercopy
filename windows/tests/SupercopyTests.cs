// Regressions of the copy logic, the same checks as the old tests/clipboard.Tests.ps1, on the real Windows clipboard
// (restored at the end). Teams itself is replaced by fixture windows and messages.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Windows.Forms;
using TeamsSupercopy;
using Message = TeamsSupercopy.Message;

static class SupercopyTests
{
    static int checks;

    static void Assert(bool condition, string label)
    {
        if (!condition) throw new Exception("FAIL: " + label);
        checks++;
        Console.WriteLine("PASS: " + label);
    }

    static void Fixture(string url, bool html)
    {
        var d = new DataObject();
        d.SetData("UnicodeText", "shared phrase");
        d.SetData("Chromium internal source URL", new MemoryStream(Encoding.UTF8.GetBytes(url + "\0")));
        if (html) d.SetData("HTML Format", "<p>shared phrase</p>");
        Clipboard.SetDataObject(d, true);
    }

    static Message Text(string t)
    {
        return new Message { Norm = t, Chat = "Fixture", Author = "Author", Time = new DateTime(2026, 11, 3, 12, 0, 0), Parts = new List<Part> { new Part { Kind = PartKind.Text, Text = t } } };
    }

    [STAThread]
    static int Main()
    {
        // every clipboard format, to put back afterwards
        var saved = new DataObject();
        IDataObject original = Clipboard.GetDataObject();
        if (original != null)
            foreach (string format in original.GetFormats(false))
            {
                object value;
                try { value = original.GetData(format, false); } catch { continue; }
                if (value is MemoryStream) value = new MemoryStream(((MemoryStream)value).ToArray());
                if (value != null) saved.SetData(format, false, value);
            }
        var fixtureWindow = new Form();
        var popoutWindow = new Form();
        try
        {
            IntPtr fixture = fixtureWindow.Handle, popout = popoutWindow.Handle;
            bool foreground = true;
            Copy.TeamsForeground = () => foreground;
            Copy.IsTeamsWindow = h => h == fixture || h == popout;
            Copy.ImageDir = Path.Combine(Path.GetTempPath(), "supercopy-tests-images");
            Assert(!Native.IsTeamsWindow(fixture), "window of another process is not a Teams window");
            Native.EventForeground = fixture;
            Native.EventOwnerRoot = fixture;

            Fixture("https://teams.microsoft.com/v2/", true);
            Assert(Copy.IsTeamsClipboard(), "native Teams rich clipboard accepted");
            foreground = false;
            Assert(!Copy.IsTeamsClipboard(), "EverTranscript/browser foreground rejected despite matching text and Teams URL");
            foreground = true;
            Native.EventForeground = new IntPtr(456);
            Assert(!Copy.IsTeamsClipboard(), "copy captured in another foreground window rejected");
            Native.EventForeground = popout;
            Native.EventOwnerRoot = popout;
            Assert(Copy.IsTeamsClipboard(), "copy from a second Teams window accepted");
            Native.EventForeground = fixture;
            Native.EventOwnerRoot = new IntPtr(456);
            Assert(!Copy.IsTeamsClipboard(), "clipboard owned by another app rejected");
            Native.EventOwnerRoot = fixture;
            Fixture("https://teams.microsoft.com/v2/", false);
            Assert(!Copy.IsTeamsClipboard(), "plain-text transcript rejected even inside native window");
            Fixture("https://example.com/", true);
            Assert(!Copy.IsTeamsClipboard(), "non-Teams source rejected");
            Fixture("https://teams.microsoft.com.evil.example/", true);
            Assert(!Copy.IsTeamsClipboard(), "lookalike Teams source rejected");
            foreach (string host in new[] { "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com" })
            {
                Fixture("https://" + host + "/v2/", true);
                Assert(Copy.IsTeamsClipboard(), host + " accepted");
            }

            Message message = Text("shared phrase");
            var messages = new List<Message> { new Message { Norm = "earlier unrelated message" }, message };
            Assert(Copy.SelectByClipboardText(messages, "shared phrase", 0).Count == 1, "matching regression fixture resolves real message");
            Assert(Copy.RemoveLinkLabel("run Link https://dev.example.com/x?id=1") == "run https://dev.example.com/x?id=1", "UIA link label stripped");
            Assert(Copy.RemoveLinkLabel("see the link here") == "see the link here", "word link without url kept");
            var linkMsg = new Message { Norm = Copy.Norm(Copy.RemoveLinkLabel("please run Link https://dev.example.com/b?id=60619")) };
            Assert(Copy.SelectByClipboardText(new List<Message> { linkMsg }, "please run https://dev.example.com/b?id=60619", 0).Count == 1, "message with link matches its copy");
            var imageOnly = new Message { Norm = "immagine", Parts = new List<Part> { new Part { Kind = PartKind.Image } } };
            var chat = new List<Message> { Text("alpha one"), Text("beta two"), imageOnly, Text("gamma three") };
            Assert(Copy.SelectByClipboardText(chat, "beta two\r\n \r\n", 0).Count == 1, "image-only neighbour left out when the copy has no image");
            var sel = Copy.SelectByClipboardText(chat, "beta two\r\n \r\n", 1);
            Assert(sel.Count == 2 && sel[1].Norm == "immagine", "image-only message after the selected text included when the copy has its image");
            Assert(Copy.SelectByClipboardText(chat, "beta two\r\n \r\ngamma three", 0).Count == 3, "message between two matched ones kept");
            Assert(Copy.SelectByClipboardText(chat, "nothing like it", 0).Count == 0, "unrelated copy matches nothing");

            var quoted = Copy.SplitParts("Inizio citazione, Mario Rossi, 03/11/2026 12:00, testo originale, fine citazione risposta", new List<ImageRef>());
            Assert(quoted.Count == 2 && quoted[0].Kind == PartKind.Quote && quoted[0].Author == "Mario Rossi" && quoted[0].Text == "testo originale" && quoted[1].Text == "risposta", "Teams quote split into quote and reply");
            var withImage = Copy.SplitParts("prima immagine dopo", new List<ImageRef> { new ImageRef { ObjectId = "x", Alt = "immagine" } });
            Assert(withImage.Count == 3 && withImage[1].Kind == PartKind.Image, "image placed where its alt text is");
            Assert(Copy.ChatTitle("Chat | Progetto X | Tenant | user@example.com | Microsoft Teams") == "Progetto X", "chat title read from the window title");

            Copy.ReadMessages = () => messages;
            Copy.HotkeyClock = System.Diagnostics.Stopwatch.StartNew();
            Copy.Marks.Clear();
            Fixture("https://teams.microsoft.com/v2/", true);
            Copy.AutoSequence = Native.GetClipboardSequenceNumber();
            Copy.Invoke("Auto");
            Assert(Clipboard.GetText().StartsWith("Teams chat: Fixture"), "accepted copy produces enriched clipboard through full formatting path");
            Assert(Clipboard.GetText().Contains("[2026-11-03 12:00] Author"), "enriched copy carries time and author");
            Assert(Clipboard.ContainsData("HTML Format"), "enriched copy carries HTML");
            Assert(!Copy.IsTeamsClipboard(), "enriched copy cannot retrigger itself");

            Copy.PlainClipSeq = 55;
            Native.EventShift = false;
            Assert(Copy.IsPlainCopyEvent(55), "Ctrl+Shift+C bypass tracks the exact clipboard sequence");
            Assert(!Copy.IsPlainCopyEvent(56), "plain-copy bypass does not leak into the next copy");
            Native.EventShift = true;
            Assert(Copy.IsPlainCopyEvent(56), "Shift held during Copy bypasses enrichment");
            Native.EventShift = false;
            Assert(!Copy.IsPlainCopyEvent(56), "Shift release restores normal enrichment");

            Fixture("https://teams.microsoft.com/v2/", true);
            Copy.AutoSequence = Native.GetClipboardSequenceNumber();
            Clipboard.SetText("newer user copy");
            Copy.OutResult(Copy.Format(new List<Message> { message }), "Auto");
            Assert(Clipboard.GetText() == "newer user copy", "pending enrichment never overwrites newer clipboard");
            Copy.AutoSequence = Native.GetClipboardSequenceNumber();
            foreground = false;
            Copy.OutResult(Copy.Format(new List<Message> { message }), "Auto");
            Assert(Clipboard.GetText() == "newer user copy", "pending enrichment cancelled after foreground changes");

            byte[] html = Copy.CfHtml("<p>è</p>");
            string head = Encoding.UTF8.GetString(html);
            int start = int.Parse(head.Substring(head.IndexOf("StartFragment:") + 14, 10)), end = int.Parse(head.Substring(head.IndexOf("EndFragment:") + 12, 10));
            Assert(Encoding.UTF8.GetString(html, start, end - start) == "<p>è</p>", "CF_HTML offsets count UTF-8 bytes");
        }
        catch (Exception e)
        {
            Console.WriteLine(e.Message);
            return 1;
        }
        finally
        {
            fixtureWindow.Dispose();
            popoutWindow.Dispose();
            Clipboard.SetDataObject(saved, true);
        }
        Console.WriteLine(checks + " checks passed");
        return 0;
    }
}
