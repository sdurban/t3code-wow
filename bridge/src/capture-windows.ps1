$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class T3WowCapture {
    [StructLayout(LayoutKind.Sequential)]
    private struct ClientRect {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ScreenPoint {
        public int X, Y;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool GetClientRect(IntPtr window, out ClientRect rect);

    [DllImport("user32.dll")]
    private static extern bool ClientToScreen(IntPtr window, ref ScreenPoint point);

    public static string Grab(int pid, int width, int height) {
        IntPtr window;
        try {
            using (var game = Process.GetProcessById(pid)) {
                window = game.MainWindowHandle;
            }
        } catch (ArgumentException) {
            return "no-window";
        }
        if (window == IntPtr.Zero) return "no-window";
        if (window != GetForegroundWindow()) return "hidden";

        // Use device pixels on both the primary and secondary displays.
        IntPtr previousDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            return CaptureClient(window, width, height);
        } finally {
            if (previousDpi != IntPtr.Zero) SetThreadDpiAwarenessContext(previousDpi);
        }
    }

    private static string CaptureClient(IntPtr window, int width, int height) {
        ClientRect client;
        var origin = new ScreenPoint();
        if (!GetClientRect(window, out client) || !ClientToScreen(window, ref origin)) return "no-window";
        var point = new Point(origin.X, origin.Y);
        var display = Screen.FromPoint(point).Bounds;
        if (!display.Contains(point)) return "hidden";

        bool screenshot = width == 0 && height == 0;
        int availableWidth = Math.Min(client.Right, display.Right - point.X);
        int availableHeight = Math.Min(client.Bottom, display.Bottom - point.Y);
        width = screenshot ? availableWidth : Math.Min(width, availableWidth);
        height = screenshot ? availableHeight : Math.Min(height, availableHeight);
        if (width <= 0 || height <= 0) return "hidden";
        using (var image = new Bitmap(width, height, PixelFormat.Format24bppRgb)) {
            using (var graphics = Graphics.FromImage(image)) {
                graphics.CopyFromScreen(point, Point.Empty, image.Size, CopyPixelOperation.SourceCopy);
            }
            if (window != GetForegroundWindow()) return "hidden";
            using (var output = new MemoryStream()) {
                if (screenshot) {
                    double scale = Math.Min(1920.0 / width, 1080.0 / height);
                    if (scale < 1) {
                        using (var resized = new Bitmap(image, Math.Max(1, (int)(width * scale)), Math.Max(1, (int)(height * scale)))) {
                            resized.Save(output, ImageFormat.Jpeg);
                        }
                    } else {
                        image.Save(output, ImageFormat.Jpeg);
                    }
                } else {
                    WritePpm(image, output);
                }
                return "ok " + Convert.ToBase64String(output.ToArray());
            }
        }
    }

    private static void WritePpm(Bitmap image, Stream output) {
        var header = Encoding.ASCII.GetBytes("P6\n" + image.Width + " " + image.Height + "\n255\n");
        output.Write(header, 0, header.Length);
        var area = new Rectangle(0, 0, image.Width, image.Height);
        var pixels = image.LockBits(area, ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        try {
            var row = new byte[image.Width * 3];
            for (int y = 0; y < image.Height; y++) {
                Marshal.Copy(IntPtr.Add(pixels.Scan0, y * pixels.Stride), row, 0, row.Length);
                for (int x = 0; x < row.Length; x += 3) {
                    byte blue = row[x];
                    row[x] = row[x + 2];
                    row[x + 2] = blue;
                }
                output.Write(row, 0, row.Length);
            }
        } finally {
            image.UnlockBits(pixels);
        }
    }
}
'@

while ($null -ne ($line = [Console]::ReadLine())) {
    $id, $gamePid, $width, $height = $line -split ' '
    try {
        $result = [T3WowCapture]::Grab([int]$gamePid, [int]$width, [int]$height)
        [Console]::WriteLine("$id $result")
    } catch {
        $message = $_.Exception.GetBaseException().Message -replace '[\r\n]+', ' '
        [Console]::WriteLine("$id error $message")
    }
}
