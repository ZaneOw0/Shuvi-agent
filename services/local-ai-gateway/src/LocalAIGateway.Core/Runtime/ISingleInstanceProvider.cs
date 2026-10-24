namespace LocalAIGateway.Core.Runtime;

public interface ISingleInstanceProvider
{
    ISingleInstanceLease? TryAcquire();
}

public interface ISingleInstanceLease : IDisposable
{
}
