import { SearchError } from './search.js';
import { startServer } from './server.js';

// Real MCP handshake/catalog, with execution disabled independently of environment credentials.
// This entry point never creates the Tavily search adapter or reads .env.
try {
  const app = await startServer(async () => { throw new SearchError('CONFIGURATION'); }, 8787);
  console.log(`Shuvi MCP 连接检查: ${app.url}`);
  console.log('仅支持握手和工具发现；搜索执行已禁用，不会调用 Tavily。');
  let closing = false;
  const stop = (): void => {
    if (closing) return;
    closing = true;
    void app.close().catch(() => { process.exitCode = 1; });
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
} catch {
  console.error('连接检查服务启动失败，请检查 8787 端口是否已被使用。');
  process.exitCode = 1;
}
