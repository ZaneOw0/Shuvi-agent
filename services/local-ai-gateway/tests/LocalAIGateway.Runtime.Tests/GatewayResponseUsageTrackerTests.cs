using System.Text;

namespace LocalAIGateway.Runtime.Tests;

public sealed class GatewayResponseUsageTrackerTests
{
    [Fact]
    public void Scanner_tracks_structural_usage_across_single_byte_chunks_and_ignores_text_content()
    {
        var recorded = new List<long>();
        var tracker = new GatewayResponseUsageTracker(recorded.Add);
        var payload = Encoding.UTF8.GetBytes(
            """
            {"choices":[{"message":{"content":"fake \"usage\": {\"total_tokens\": 999}"}}],"usage":{"prompt_tokens":7,"completion_tokens":5,"total_tokens":12}}
            """);

        foreach (var value in payload)
        {
            tracker.Append([value]);
        }

        Assert.Equal([12], recorded);
    }

    [Fact]
    public void Scanner_sums_anthropic_usage_objects_from_separate_sse_events()
    {
        var recorded = new List<long>();
        var tracker = new GatewayResponseUsageTracker(recorded.Add);
        var payload = Encoding.UTF8.GetBytes(
            """
            event: message_start
            data: {"type":"message_start","message":{"usage":{"input_tokens":3,"output_tokens":0}}}

            event: message_delta
            data: {"type":"message_delta","usage":{"output_tokens":5}}

            """);

        tracker.Append(payload.AsSpan(0, 31));
        tracker.Append(payload.AsSpan(31));

        Assert.Equal([3, 5], recorded);
    }

    [Fact]
    public async Task Tracking_content_preserves_response_bytes_and_records_nested_responses_usage()
    {
        var recorded = new List<long>();
        var payload = Encoding.UTF8.GetBytes(
            """
            {"type":"response.completed","response":{"output":[{"content":[{"text":"ok"}]}],"usage":{"input_tokens":11,"output_tokens":4,"total_tokens":15}}}
            """);
        using var content = new GatewayUsageTrackingContent(
            new ByteArrayContent(payload),
            new GatewayResponseUsageTracker(recorded.Add));

        var copied = await content.ReadAsByteArrayAsync();

        Assert.Equal(payload, copied);
        Assert.Equal([15], recorded);
    }

    [Fact]
    public void Scanner_ignores_negative_fractional_and_overflowing_token_values_without_throwing()
    {
        var recorded = new List<long>();
        var tracker = new GatewayResponseUsageTracker(recorded.Add);

        tracker.Append(Encoding.UTF8.GetBytes(
            """
            {"usage":{"total_tokens":-1}},{"usage":{"total_tokens":1.5}},{"usage":{"total_tokens":999999999999999999999999999999}}
            """));

        Assert.Empty(recorded);
    }
}
