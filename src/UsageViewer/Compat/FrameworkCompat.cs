using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

#if NETFRAMEWORK
namespace System.Runtime.CompilerServices
{
    // Enables records and init-only setters when targeting .NET Framework.
    internal static class IsExternalInit { }
}
#endif

namespace UsageViewer
{
    // The app targets .NET Framework 4.8 (preinstalled on Windows 10/11) so the
    // portable build needs no bundled runtime. These helpers keep the newer
    // .NET behaviour the code relied on; the regression tests still run on
    // modern .NET, where they defer to the built-in APIs.
    internal static class FrameworkCompat
    {
        internal static void MoveReplacing(string source, string destination)
        {
#if NETFRAMEWORK
            // Same Win32 call File.Move(source, destination, true) uses on .NET.
            if (MoveFileEx(source, destination, MoveFileReplaceExisting | MoveFileCopyAllowed)) return;
            var error = Marshal.GetLastWin32Error();
            var message = new Win32Exception(error).Message;
            if (error == ErrorAccessDenied) throw new UnauthorizedAccessException(message);
            throw new IOException(message, error);
#else
            File.Move(source, destination, true);
#endif
        }

        internal static string GetRelativePath(string relativeTo, string path)
        {
#if NETFRAMEWORK
            // Only containment matters to callers: paths outside relativeTo come
            // back rooted, which they reject like a "..\" result.
            var root = Path.GetFullPath(relativeTo).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            var full = Path.GetFullPath(path);
            if (string.Equals(full, root, StringComparison.OrdinalIgnoreCase)) return ".";
            var prefix = root + Path.DirectorySeparatorChar;
            return full.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? full.Substring(prefix.Length) : full;
#else
            return Path.GetRelativePath(relativeTo, path);
#endif
        }

        internal static void KillTree(Process process)
        {
#if NETFRAMEWORK
            try
            {
                using var taskkill = Process.Start(new ProcessStartInfo
                {
                    FileName = "taskkill.exe",
                    Arguments = $"/PID {process.Id} /T /F",
                    UseShellExecute = false,
                    CreateNoWindow = true
                });
                taskkill?.WaitForExit(5000);
            }
            catch { }
            if (!process.HasExited) process.Kill();
#else
            process.Kill(entireProcessTree: true);
#endif
        }

#if NETFRAMEWORK
        private const int MoveFileReplaceExisting = 0x1;
        private const int MoveFileCopyAllowed = 0x2;
        private const int ErrorAccessDenied = 5;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
#endif
    }
}
