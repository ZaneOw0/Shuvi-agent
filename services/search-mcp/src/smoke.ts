import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import { CallToolResultSchema } from '@modelcontextprotocol/sdk/types.js';
import { inputSchema, outputSchema } from './search.js';

// No env-file loading here: only the server process needs the provider credential.
const client = new Client({ name: 'shuvi-search-smoke', version: '0.1.0' });
const transport = new StreamableHTTPClientTransport(new URL('http://127.0.0.1:8787/mcp'));
try {
  await client.connect(transport);
  const tools = await client.listTools();
  console.log('可用工具:', tools.tools.map(tool => tool.name).join(', '));
  if (!tools.tools.some(tool => tool.name === 'web_search')) throw new Error('Tool missing');
  if (process.argv.includes('--search')) {
    // Explicit opt-in: exactly one fixed public query; no personal data.
    const result = await client.callTool({ name: 'web_search', arguments: inputSchema.parse({
      query: 'HarmonyOS ArkUI 官方开发文档', maxResults: 3
    }) }, CallToolResultSchema, { timeout: 20_000 });
    if (result.isError) {
      console.error('真实搜索失败。请在本机检查凭据、网络和额度；未记录为通过。');
      process.exitCode = 1;
    } else {
      const validated = outputSchema.parse(result.structuredContent);
      console.log(JSON.stringify(validated, null, 2));
      console.log(validated.results.length ? '真实搜索完成，请人工核对来源。' : '调用完成，但无结果，尚未验证来源展示。');
    }
  } else {
    console.log('仅握手和工具发现通过，未发送搜索请求。真实搜索使用 npm.cmd run smoke -- --search。');
  }
} catch {
  console.error('验证未通过，请确认服务已在默认端口启动，以及协议或返回结果是否符合约定。');
  process.exitCode = 1;
} finally {
  await transport.terminateSession().catch(() => {});
  await client.close();
}
