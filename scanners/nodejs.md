# Node.js / npm / TypeScript 扫描规则

## 检测条件

**主要**：
- 存在 `package.json`

**子类型判断**：
- 含 `vue` 依赖 → Vue 3 前端
- 含 `react` 依赖 → React 前端
- 含 `next` 依赖 → Next.js
- 含 `nuxt` 依赖 → Nuxt.js
- 含 `@nestjs/core` 依赖 → NestJS
- 含 `@remix-run/react` 依赖 → Remix
- 含 `astro` 依赖 → Astro
- 含 `@angular/core` 依赖 → Angular
- 含 `@sveltejs/kit` 依赖 → SvelteKit
- 含 `express` / `koa` / `fastify` / `hono` → Node.js 后端
- 含 `typescript` 或 `tsconfig.json` → TypeScript 项目
- 含 `vite` → Vite 构建
- 含 `webpack` → Webpack 构建

## 技术栈提取

### 从 package.json 提取

```
dependencies + devDependencies → 版本号
```

重点关注：
- 运行时：node（engines.node）
- 框架：vue, react, next, nuxt, express, koa, fastify, hono, nestjs
- UI 库：element-plus, ant-design, vuetify, tailwindcss
- 状态管理：pinia, vuex, redux, zustand
- 构建：vite, webpack, rollup, esbuild, tsup
- 测试：vitest, jest, mocha, playwright
- 工具：typescript, eslint, prettier

### 从 tsconfig.json 提取
- TypeScript 版本
- target（编译目标）
- `compilerOptions.paths`（路径别名映射，如 `@/*: ["./src/*"]`）
- `compilerOptions.baseUrl`（路径解析基准目录）

> **路径别名解析**：在所有涉及 import 追踪的章节（Controller-to-Module 关联、路由文件导入等），应首先从 `tsconfig.json` 的 `compilerOptions.paths` 和 `compilerOptions.baseUrl` 构建路径别名解析表。非相对路径 import（如 `@/users/users.controller`）通过该表映射到实际文件路径，相对路径 import 按 TypeScript 标准模块解析规则处理。

## API 端点提取（Node.js 后端）

### Express
```javascript
app.get('/path', handler)
app.post('/path', handler)
router.get('/path', handler)
```

**高级模式**：
- `app.route('/path').get(h1).post(h2).put(h3)` — 链式调用，同一路径多个方法一次性注册
- Router 实例化与挂载跨文件追踪：检测 `const router = express.Router()` 创建，追踪 `module.exports = router` / `export default router` 导出，再到其他文件中 `app.use('/prefix', router)` 挂载。跨文件时追踪 import/require 链
- `app.param('id', callback)` — 参数级中间件，为特定参数名注册预处理逻辑

### Koa
```javascript
router.get('/path', handler)
router.post('/path', handler)
```

**高级模式**：
- `router.allowedMethods()` 检测 — 自动处理 OPTIONS 请求（返回 Allow 头）和 405 Method Not Allowed 响应，是 Koa 路由的标准配置

### Fastify
```javascript
fastify.get('/path', options, handler)
fastify.post('/path', options, handler)
```

**高级模式**：
- `fastify.register(plugin, { prefix: '/v1' })` + 作用域路由递归扫描：插件注册后其内部定义的路由自动继承插件前缀。追踪 `register()` 调用并展开被注册插件的路由定义
- `fastify.route({ method: 'GET', url: '/path', handler })` — 声明式路由方法，提取 `method` 和 `url` 字段
- `fastify.all('/path', handler)` — 匹配所有 HTTP 方法

### Hono
```typescript
app.get('/path', (c) => {...})
app.post('/path', (c) => {...})
```

**高级模式**：
- `app.route('/prefix', subApp)` — 子应用挂载，将子应用的所有路由挂载到指定前缀下
- `c.req.param('key')` — 路径参数提取
- `c.req.query('key')` — 查询参数提取
- `c.req.json()` / `c.req.text()` / `c.req.formData()` — 请求体提取（context 方法）
- RPC 模式：`hono/client` 的 `hc` 类型安全调用检测（`app.get('/path', ...)` 自动生成客户端类型）

### 通用路由模式（所有后端框架均适用）

**动态路由参数**（`:param` 模式）：
```
/users/:id            → 必选动态参数
/users/:id/posts      → 嵌套动态参数
/files/:path(.*)      → 正则约束（Express）
/users/{id}           → 花括号风格（Fastify）
```

**全方法匹配**：`app.all('/path', handler)` — 匹配所有 HTTP 方法。

**前缀挂载**：`app.use('/prefix', router)` — 将子路由挂载到指定前缀下。Koa/Hono 同理。

## 路由提取（前端框架）

### Vue Router
- 扫描 `router/index.*` 或 `src/router/` 目录
- 定位 `createRouter({ routes: [...] })` 调用，提取 `routes` 数组
- 每条 route 提取 `{ path, name, component }` 字段
- 递归提取 `children` 数组内的嵌套路由（路径自动拼接父路径前缀）
- 识别 path 中 `:param` 动态段（如 `/users/:id`）
- 提取 `meta` 字段（路由元信息，含 `title`/`requiresAuth` 等）和路由守卫（`beforeEnter`）

### React Router

**版本检测**：先检查 `react-router-dom` 的 major version（`package.json` 中 `dependencies`/`devDependencies`），确定提取策略。

- **v5 模式**：`<Route path="/foo" component={Comp} />` → 提取 `path` 和 `component` 引用
- **v5 嵌套**：`<Route path="/parent"><Route path="child" .../></Route>` → 识别嵌套路由，路径自动拼接
- **v6 模式**：`<Route path="/foo" element={<Comp />} />` → 提取 `path` 和 `element` 组件引用
- **v6.4+ 文件路由**：检查 `src/routes/` 目录结构（若使用 `createBrowserRouter` 加载文件路由约定）
- **懒加载**：识别 `React.lazy(() => import('./Page'))` 或 `lazy(() => import('./route'))` 懒加载路由
- **布局路由**：v6 中 `{ path, element: <Layout />, children: [...] }` 布局路由提取

## 配置项提取

### 环境变量
- `.env.example`、`.env.development`（仅读取 `.env.example`，不读取含密钥的 `.env` 文件）
- 提取 `KEY=VALUE` 对（值的部分脱敏）

### Vite 配置
- `vite.config.*`
- 提取 `server.port`、`server.proxy`（代理目标）

### Next.js 配置
- `next.config.*`（`next.config.js`/`next.config.mjs`/`next.config.ts`）
- 提取关键配置：`basePath`、`i18n`、`images`（远程域名白名单）、`experimental`
- **重定向与重写**：提取 `async redirects()` 返回值（`source`/`destination`/`permanent`）、`async rewrites()` 返回值（`source`/`destination`）
- **请求头**：提取 `async headers()` 返回值（`source`/`headers` 数组）
- **中间件配置**：检测根目录 `middleware.ts`/`middleware.js`，提取 `config.matcher` 数组（路径匹配模式）

## 项目结构

### 典型 Node.js 后端
```
src/
├── index.ts 或 app.ts       # 入口
├── routes/                   # 路由
├── controllers/              # 控制器
├── services/                 # 业务逻辑
├── models/                   # 数据模型
├── middleware/               # 中间件
└── utils/                    # 工具函数
```

### 典型 Vue 3 前端
```
src/
├── main.ts                   # 入口
├── App.vue                   # 根组件
├── views/ 或 pages/          # 页面
├── components/               # 组件
├── api/                      # API 请求
├── stores/ 或 store/         # 状态管理
├── router/                   # 路由
└── utils/                    # 工具函数
```

## 包管理器检测

- `package-lock.json` → npm
- `yarn.lock` → Yarn
- `pnpm-lock.yaml` → pnpm
- `bun.lockb` → Bun
- `bunfig.toml` → Bun（项目级配置文件）

用于更新 README 中的安装/启动命令。

## Monorepo 检测

- `pnpm-workspace.yaml` 存在 → pnpm Monorepo
- `lerna.json` → Lerna
- `nx.json` → Nx
- `turbo.json` → Turborepo
- `rush.json` → Rush.js
- `package.json` 含 `workspaces` → npm/yarn workspaces
- 多个子目录各含独立 `package.json` → 手动 workspaces

Monorepo 项目应递归扫描各子包的 `package.json`，并在 README 中体现子包列表。

## NestJS 路由提取

```typescript
@Controller('users')
export class UserController {
  @Get(':id')
  findOne(@Param('id') id: string) {}
  
  @Post()
  create(@Body() dto: CreateUserDto) {}
}
```

- `@Controller('prefix')` → 路由前缀
- `@Get(':id')` / `@Post()` / `@Put(':id')` / `@Delete(':id')` / `@Patch(':id')`
- 检查 `@Module({ controllers: [...] })` 注册

### 参数装饰器识别表

| 装饰器 | 用途 | 示例 |
|--------|------|------|
| `@Param('key')` | 路径参数 | `@Param('id') id: string` |
| `@Query('key')` | URL 查询参数 | `@Query('page') page: number` |
| `@Body()` | 请求体 | `@Body() dto: CreateDto` |
| `@Req()` / `@Request()` | 原始请求对象 | `@Req() req: Request` |
| `@Res()` / `@Response()` | 原始响应对象 | `@Res() res: Response` |
| `@Headers('key')` | 请求头 | `@Headers('authorization') token: string` |

> `@Res()` passthrough 模式：传入 `{ passthrough: true }` 时仍由框架自动发送返回值。

### Controller-to-Module 跨文件关联

1. **扫描 Controller 文件**：扫描所有 `*.controller.ts` 文件，提取 `export class` 类名和 `@Controller(prefix)` 装饰器参数作为路由前缀
2. **扫描 Module 文件**：扫描所有 `*.module.ts` 文件，提取 `@Module({ controllers: [...] })` 装饰器数组中的标识符名称列表
3. **构建路径别名映射表**：读取项目根 `tsconfig.json` 的 `compilerOptions.paths` 和 `compilerOptions.baseUrl`，构建路径别名 → 实际路径的映射表。若无 `tsconfig.json`，则仅支持相对路径解析
4. **解析 import 语句**：对每个 `.module.ts` 文件，解析其 import 语句：
   - 相对路径（`./` 或 `../` 开头）：按 TypeScript 模块解析规则，相对于当前文件目录定位目标文件。依次尝试 `.ts`、`.js`、`/index.ts`、`/index.js` 扩展名
   - 非相对路径（如 `src/users/users.controller`）：结合 `paths`/`baseUrl` 映射表解析。若 import 指向目录，检查 `index.ts` barrel export
5. **符号精确匹配**：将 import 的符号名与 `controllers: [...]` 数组中的标识符做精确匹配，建立 Controller 类 → Module 文件的归属关系
6. **兜底解析**：未匹配的标识符 — 检查 import 源文件是否包含重新导出（`export { X } from '...'`）。仍无法匹配时，从文件路径推断模块名（如 `src/users/users.controller.ts` → Users，`src/admin/orders/admin-orders.controller.ts` → Admin/Orders）

**兜底规则**：以上步骤仍无法关联时，在输出中标注 `[Unlinked]`。

## Next.js 路由提取

**Pages Router（`pages/`）与 App Router（`app/`）区分**：
- 存在 `pages/` 目录 → Pages Router（传统路由）：路由基于文件路径+文件名，动态路由使用 `[param].tsx` 文件名；API 路由位于 `pages/api/`；使用 `getServerSideProps`/`getStaticProps`/`getStaticPaths` 数据获取
- 存在 `app/` 目录 → App Router（新路由）：路由基于文件夹+`page.tsx`，支持 React Server Components；API 路由使用 `route.ts`
- 两者共存 → 混合模式，App Router 路由优先级高于 Pages Router

### App Router 目录结构

```
app/
├── page.tsx            → /
├── users/
│   ├── page.tsx        → /users
│   └── [id]/
│       └── page.tsx    → /users/:id (动态路由)
├── shop/
│   └── [[...filters]]/
│       └── page.tsx    → /shop 和 /shop/a/b (可选通配)
├── api/
│   └── users/
│       └── route.ts    → /api/users (API 路由)
├── (marketing)/
│   └── page.tsx        → / (路由分组，不影响 URL)
├── @modal/
│   └── page.tsx        → 并行路由插槽
├── feed/
│   └── (..)photos/
│       └── page.tsx    → 拦截上一级路由
└── _components/
    └── Header.tsx      → 私有文件夹（不影响路由）
```

### 动态段类型

| 目录名 | 含义 |
|--------|------|
| `[param]` | 必选动态参数 |
| `[...slug]` | 通配路由（匹配多段） |
| `[[...slug]]` | 可选通配路由（匹配父路由+子路径） |
| `(group)` | 路由分组（不影响 URL） |

### 并行路由插槽

`@modal`、`@sidebar` 等 `@` 前缀目录为并行插槽，在 `layout.tsx` 中以同名 prop 接收。

**`default.tsx` 必要性**：每个并行插槽必须包含 `default.tsx` 文件，作为插槽未激活时的默认回退渲染。若缺少 `default.tsx`，导航到不包含该插槽的页面时返回 404。

### 拦截路由

| 模式 | 含义 |
|------|------|
| `(.)folder` | 同层级拦截 |
| `(..)folder` | 上一层级拦截 |
| `(...)folder` | 从根目录拦截 |

### 私有文件夹

`_components`、`_lib` 等下划线前缀目录/文件不会被路由系统识别。

### route.ts 方法导出识别

```typescript
export async function GET(request: Request) { ... }
export async function POST(request: Request) { ... }
export async function PUT(request: Request) { ... }
export async function PATCH(request: Request) { ... }
export async function DELETE(request: Request) { ... }
```

扫描 `route.ts`/`route.js` 中所有以大写的 HTTP 方法名导出的 async function（不限固定列表，支持 GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS 等标准方法及自定义扩展方法）。

### Route Segment Config

检测 `route.ts` 和 `page.tsx` 中的段配置导出：
- `export const dynamic = 'force-dynamic' | 'force-static' | 'auto'` — 动态/静态渲染行为
- `export const revalidate = 3600` — ISR 重新验证间隔（秒）
- `export const dynamicParams = true | false` — 动态参数是否按需生成尚未预渲染的页面
- `export const fetchCache = 'force-cache' | 'only-no-store' | ...` — fetch 请求缓存策略
- `export const runtime = 'nodejs' | 'edge'` — 运行时环境
- `export const preferredRegion = 'home' | 'edge'` — 部署区域偏好（仅 Vercel 平台）

### Middleware

检测根目录 `middleware.ts`/`middleware.js` 文件：
- 提取 `config.matcher` 数组 — 指定中间件应用的路径模式
- 导出的 `middleware` 函数用于重定向、URL 重写、请求头修改等请求拦截逻辑

## Deno 检测

- 存在 `deno.json` 或 `deno.jsonc` → Deno 项目
- Deno 项目可能无 `package.json`，需检查 `deno.json` 中的 `imports` 和 `tasks`
- 支持 `Deno.serve()` 路由提取

## 未覆盖场景（已知限制）

- tRPC (createRouter/procedure)：需识别 `@trpc/server` 依赖并提取 `.query()`/`.mutation()` 定义
- GraphQL (Apollo/Yoga/Nexus)：需识别 `typeDefs` 和 `resolvers`
- SvelteKit（`@sveltejs/kit`）/ SolidStart（`@solidjs/start`）/ Astro（`astro`）：做基本依赖名检测，暂不深入提取路由
- Remix（`@remix-run/react`）：做基本依赖名检测，文件路由（`routes/` 目录）和 `loader`/`action` 函数暂不提取
- Nuxt.js：通过 `nuxt` 依赖检测，暂不深入解析 `pages/` 目录
- Next.js UI 约定文件（`loading.tsx`/`error.tsx`/`not-found.tsx`/`template.tsx`/`global-error.tsx`）：做存在性检测，暂不提取具体错误/加载配置
- Angular（`@angular/core`）：路由配置（`RouterModule.forRoot` + `Routes` 数组）暂不提取
- WebSocket 端点（`ws`/`Socket.IO`/`@nestjs/websockets` 的 `@WebSocketGateway`/`@fastify/websocket`）：暂不提取与 HTTP 路由不同的升级路径
- Bun 特定 API：`Bun.serve()` 等不被提取

## 输出格式

所有扫描结果统一使用结构化 JSON 输出。各维度独立数组，条目间通过共享键（如文件路径、模块名）关联。

### 端点提取

```json
{
  "endpoints": [
    {
      "method": "GET",
      "path": "/api/users/:id",
      "canonicalForm": "GET /api/users/:id",
      "confidence": "high",
      "file": "src/users/users.controller.ts",
      "line": 15,
      "framework": "NestJS",
      "module": "UsersModule",
      "decorators": ["@Get(':id')", "@Param('id')"],
      "params": ["id"]
    },
    {
      "method": "POST",
      "path": "/api/users",
      "canonicalForm": "POST /api/users",
      "confidence": "high",
      "file": "src/users/users.controller.ts",
      "line": 20,
      "framework": "NestJS",
      "module": "UsersModule",
      "decorators": ["@Post()", "@Body()"],
      "requestBody": "CreateUserDto"
    },
    {
      "method": "GET",
      "path": "/items/[id]",
      "canonicalForm": "GET /items/[id]",
      "confidence": "high",
      "file": "app/items/[id]/page.tsx",
      "line": null,
      "framework": "Next.js App Router",
      "type": "page",
      "segmentConfig": {
        "dynamic": "auto",
        "revalidate": false
      }
    }
  ]
}
```

### 依赖提取

```json
{
  "dependencies": [
    {
      "name": "next",
      "version": "^14.2.0",
      "type": "framework",
      "ecosystem": "npm"
    },
    {
      "name": "@nestjs/core",
      "version": "^10.3.0",
      "type": "framework",
      "ecosystem": "npm"
    },
    {
      "name": "typescript",
      "version": "^5.4.0",
      "type": "devDependency",
      "ecosystem": "npm"
    }
  ],
  "packageManager": {
    "name": "pnpm",
    "lockFile": "pnpm-lock.yaml",
    "installCommand": "pnpm install",
    "runCommand": "pnpm dev"
  },
  "isTypeScript": true,
  "tsconfig": {
    "target": "ES2022",
    "paths": {
      "@/*": ["./src/*"]
    },
    "baseUrl": "."
  }
}
```

### 配置提取

```json
{
  "configuration": {
    "envFiles": [".env.example", ".env.development"],
    "envVars": [
      {"key": "DATABASE_URL", "default": null, "sensitive": true},
      {"key": "PORT", "default": "3000", "sensitive": false}
    ],
    "vite": {
      "server": {"port": 5173},
      "proxy": {"/api": "http://localhost:3000"}
    },
    "next": {
      "basePath": null,
      "rewrites": [
        {"source": "/api/:path*", "destination": "https://external-api.com/:path*"}
      ],
      "redirects": [],
      "headers": [],
      "middleware": {
        "file": "middleware.ts",
        "matcher": ["/dashboard/:path*", "/api/:path*"]
      }
    }
  }
}
```

### 子类型与路由汇总

```json
{
  "subtype": ["NestJS", "Next.js", "TypeScript"],
  "routerSummary": {
    "totalEndpoints": 12,
    "frameworks": {
      "NestJS": 5,
      "Next.js App Router": 4,
      "Next.js Pages Router": 0
    },
    "dynamicParams": ["id", "slug"],
    "unlinkedControllers": {
      "count": 1,
      "items": ["HealthController → [Unlinked]"]
    },
    "knownLimitations": ["tRPC endpoints not extracted", "GraphQL resolvers not extracted"]
  }
}
```