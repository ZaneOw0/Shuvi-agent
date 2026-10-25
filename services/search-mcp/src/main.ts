import { createSearch } from './search.js';
import { startServer } from './server.js';

const port = Number(process.env.PORT ?? '8787');
if (!Number.isInteger(port) || port < 1024 || port > 65535) {
  console.error('PORT 必须是 1024–65535 的整数。');
  process.exitCode = 1;
} else {
  try {
    const app = await startServer(createSearch({ apiKey: process.env.TAVILY_API_KEY ?? '' }), port);
    console.log(`Shuvi 搜索 MCP（仅本机开发）: ${app.url}`);
    console.log('未配置凭据时可发现工具；实际搜索会明确返回 CONFIGURATION。');
    let closing = false;
    const stop = (): void => {
      if (closing) return;
      closing = true;
      void app.close().catch(() => { process.exitCode = 1; });
    };
    process.once('SIGINT', stop);
    process.once('SIGTERM', stop);
  } catch {
    console.error('服务启动失败，请检查端口是否占用及本机配置。');
    process.exitCode = 1;
  }
}
