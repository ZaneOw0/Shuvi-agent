using System.Security.Principal;
using LocalAIGateway.Core.Runtime;

namespace LocalAIGateway.Windows;

public sealed class WindowsCurrentUserSingleInstanceProvider : ISingleInstanceProvider
{
    private readonly string mutexName;

    public WindowsCurrentUserSingleInstanceProvider(string scope = "runtime")
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The Local AI Gateway single-instance guard requires Windows.");
        }

        ValidateScope(scope);
        using var identity = WindowsIdentity.GetCurrent(TokenAccessLevels.Query);
        var sid = identity.User?.Value
            ?? throw new InvalidOperationException("The current Windows user SID is unavailable.");
        mutexName = $"Global\\LocalAIGateway.{scope}.{sid}";
    }

    public ISingleInstanceLease? TryAcquire()
    {
        var mutex = new Mutex(initiallyOwned: false, mutexName, out var createdNew);
        if (!createdNew)
        {
            mutex.Dispose();
            return null;
        }

        return new Lease(mutex);
    }

    private static void ValidateScope(string scope)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(scope);
        if (scope.Length > 64 || scope.Any(character =>
                !char.IsAsciiLetterOrDigit(character) &&
                character is not '.' and not '-' and not '_'))
        {
            throw new ArgumentException("The single-instance scope is malformed.", nameof(scope));
        }
    }

    private sealed class Lease(Mutex mutex) : ISingleInstanceLease
    {
        private Mutex? mutex = mutex;

        public void Dispose() => Interlocked.Exchange(ref mutex, null)?.Dispose();
    }
}
