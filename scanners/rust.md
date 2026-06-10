# Rust 扫描规则

## 检测条件

**主要**：
- 存在 `Cargo.toml` 文件

**子类型判断**：
- `Cargo.toml` 含 `[[bin]]` → 二进制应用
- `Cargo.toml` 含 `[lib]` → 库
- 含 `actix-web` 依赖 → Actix-web 后端
- 含 `axum` 依赖 → Axum 后端
- 含 `rocket` 依赖 → Rocket 后端
- 含 `warp` 依赖 → Warp 后端
- 含 `poem` 依赖 → Poem 后端
- 含 `salvo` 依赖 → Salvo 后端
- 含 `clap` 且无 Web 框架 → CLI 工具
- 含 `structopt` → CLI 工具
- `Cargo.toml` 含 `[workspace]` → Workspace 多 crate
- 含 `tauri` 依赖 → Tauri 桌面应用
- 含 `leptos` / `dioxus` / `yew` 依赖 → WASM 前端
- 含 `pyo3` / `maturin` 依赖 → Python 绑定
- 含 `napi` / `napi-derive` / `neon` 依赖 → Node.js 原生插件
- `#![no_std]` + `embedded-hal` → 嵌入式/固件
- 含 `bevy` 依赖 → 游戏引擎

## 技术栈提取

### Cargo.toml

```toml
[package]
name = "my-app"
version = "0.1.0"
edition = "2021"

[dependencies]
actix-web = "4"
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["full"] }

[dev-dependencies]
cargo-tarpaulin = "0.31"

[build-dependencies]
tonic-build = "0.12"
```

提取：
- `[dependencies]` → 运行时依赖（含 version 和 features）
- `[dev-dependencies]` → 开发依赖
- `[build-dependencies]` → 构建依赖
- `edition` → Rust edition

重点关注的依赖类别：
- Web 框架：actix-web, axum, rocket, warp, poem, salvo
- 数据库：diesel, sqlx, sea-orm, rusqlite, mongodb, redis
- 序列化：serde, serde_json, toml
- 异步：tokio, async-std, smol
- CLI：clap, structopt, dialoguer, indicatif, console
- HTTP 客户端：reqwest, hyper, ureq
- 模板：tera, askama, handlebars
- 日志：tracing, log, env_logger
- 测试：cargo-tarpaulin, proptest, mockall
- gRPC：tonic, prost
- 桌面：tauri
- WASM：leptos, dioxus, yew
- FFI：pyo3, maturin, napi, napi-derive, neon

### target-scoped 条件依赖

```toml
[target.'cfg(windows)'.dependencies]
winapi = "0.3"

[target.'cfg(feature = "gui")'.dependencies]
egui = "0.27"

[target.'cfg(not(target_arch = "wasm32"))'.dependencies]
tokio = { version = "1", features = ["full"] }
```

- `[target.'cfg(...)'.dependencies]` / `[target.'cfg(...)'.dev-dependencies]` / `[target.'cfg(...)'.build-dependencies]` → 条件依赖
- 提取 cfg 条件表达式和目标依赖列表
- 标注为 `[Conditional: <condition>]`（如 `[Conditional: windows]`、`[Conditional: feature="gui"]`）
- 条件依赖不在默认编译范围，需该 cfg 条件为真时才被激活

## API 端点提取

### Actix-web

```rust
use actix_web::{web, App, HttpResponse, get, post};

#[get("/users/{id}")]
async fn get_user(path: web::Path<i32>) -> HttpResponse { ... }

#[post("/users")]
async fn create_user(user: web::Json<User>) -> HttpResponse { ... }

App::new()
    .service(get_user)
    .service(create_user)
    .route("/health", web::get().to(health_check))
```

扫描模式：
- `#[get("/path")]` / `#[post("/path")]` / `#[put("/path")]` / `#[delete("/path")]` / `#[patch("/path")]`（use 导入的显式属性宏）
- `#[web::get("/path")]` 等内联属性风格（不通过 use 导入）
- `.route("/path", web::get().to(handler))` / `.route("/path", web::post().to(handler))`
- `web::scope("/prefix")` → 前缀路由组
- `web::resource("/path")` → 资源式路由注册（`.route(web::get().to(...))` 链）
- `.configure(config_fn)` → 跨函数路由配置——追踪 config 函数体内的 `.service()`/`.route()`/`web::scope()`/`web::resource()` 调用。搜索 fn 参数类型为 `&mut web::ServiceConfig` 的函数（或 `&mut ServiceConfig`），提取其中的路由注册。config 函数可使用 `web::scope()` 为内部所有路由施加共同前缀。

### Axum

```rust
use axum::{Router, routing::get};

let app = Router::new()
    .route("/users", get(list_users).post(create_user))
    .route("/users/:id", get(get_user).delete(delete_user))
    .nest("/admin", admin_routes)
    .nest_service("/static", static_service);
```

扫描模式：
- `.route("/path", get(handler))` / `.route("/path", post(handler))` 等
- `.route("/path", get(handler).post(handler2))` ← 多个方法链在同一路径
- `.nest("/prefix", router)` → 嵌套路由（合并子 Router 并加前缀）
- `.nest_service("/prefix", service)` → 嵌套服务（如 `tower::fs::ServeDir`）
- `.merge(router)` → **合并另一个 Router 的全部路由**（Axum 最常用的多模块路由组合方式）
- `axum::routing::get` / `post` / `put` / `delete` / `patch`

**merge 跨文件追踪规则**：搜索 `.merge(` 调用，提取被合并的 Router 变量名 → 追踪该变量的定义位置 → 递归提取其中所有 `.route()` 和 `.nest()`。

- **追踪深度**：2 级（直接变量定义 + 函数返回值追踪）。`fn create_router() -> Router { Router::new().route(...) }` 这种工厂函数 → 追踪返回值中的 Router 定义，但工厂函数内调用的下一级工厂函数不再展开。
- **Crate 边界**：仅追踪当前 crate 内的 Router 定义。跨 crate 导入的 Router（如 `use other_crate::router;`）标注 `[ExternalRouter]` 并终止追踪。
- **循环引用防护**：维护已访问 Router 变量名集合，检测到重复变量名时终止递归，标注 `[CircularRef]`。
- **链式 merge**：识别 `.merge(r1).merge(r2).merge(r3)` 多 Router 链式调用模式，逐一追踪每个被合并的 Router。

**补充路由方法**：
- `.fallback(handler)` → 404 兜底处理器，标注 `"isFallback": true`
- `.fallback_service(service)` → 兜底服务
- `.layer(tower_layer)` → 全局中间件层（作用于整个 Router）
- `.route_layer(layer)` → 路由级中间件层（仅作用于紧邻的 `.route()`）
- `.with_state(Arc<AppState>)` → 共享应用状态（所有 handler 可通过 `State<AppState>` 提取器访问）
- MethodRouter 变量模式：`let user_routes = get(list).post(create).delete(remove);` → `.route("/users", user_routes);` — 提取 MethodRouter 变量赋值链中所有 HTTP 方法，追踪变量引用到 `.route()` 调用
- `axum::routing::any(handler)` → 全方法匹配（匹配 GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/TRACE/CONNECT），标注 `"method": "ANY"`
- `axum::routing::on(MethodFilter, handler)` → 自定义方法组合，展开 `MethodFilter` 枚举值（如 `get().post()`）为具体方法列表

### Rocket

```rust
#[macro_use] extern crate rocket;

#[get("/users/<id>")]
fn get_user(id: i32) -> Json<User> { ... }

#[post("/users", data = "<user>")]
fn create_user(user: Json<User>) -> Json<User> { ... }

rocket::build()
    .mount("/", routes![index, health])
    .mount("/api", routes![get_user, create_user])
    .register("/", catchers![not_found])
    .attach(CorsFairing);
```

扫描模式：
- `#[get("/path")]` / `#[post("/path")]` / `#[put("/path")]` / `#[delete("/path")]` / `#[patch("/path")]`
- `#[get("/users/<id>")]` → 路径参数
- `.mount("/prefix", routes![handler1, handler2])` 是 Rocket 路由注册核心——属性宏仅定义 handler，`routes![]` 宏才真正注册
- `#[catch(code)]` 错误处理器 + `.register("/", catchers![...])`
- `impl Fairing` + `.attach()` 中间件（Fairing）
- `#[launch]` 属性宏（Rocket 0.5+）→ 标注在返回 `Rocket<Build>` 或 `_` 的 fn 上，自动从 Cargo.toml 依赖版本判断 Rocket 版本
- `#[route(GET, path = "/path")]` 泛化路由属性（Rocket 0.5+，等价于 `#[get("/path")]` 但更灵活——method 可为 GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS 任意组合）
- 异步 Fairing 生命周期钩子：`on_ignite` / `on_liftoff` / `on_request` / `on_response` / `on_sent`（Rocket 0.5+ 新增 `on_sent`）
- 路径参数类型由 handler 函数的参数类型决定（`impl FromParam`），提取 params 时需从 handler 的函数签名获取参数名和类型。如 `fn get_user(id: i32)` → `["id: i32"]`，`fn find(name: &str)` → `["name: &str"]`

### Warp

```rust
let users = warp::path("users");
let list = users.and(warp::get()).map(|| ...);
let create = users.and(warp::post()).and(warp::body::json()).map(|u| ...);
let get_one = warp::path("users")
    .and(warp::path::param::<i32>())
    .and(warp::get())
    .map(|id| ...);
let api = warp::path("api").and(list.or(create).or(get_one).unify());
```

扫描模式：
- `warp::path("xxx")` → 路径段
- `warp::path::param::<T>()` → 路径参数（类型决定解析方式）
- `warp::path::end()` → 路径终止符
- `warp::get()` / `warp::post()` / `warp::put()` / `warp::delete()` → HTTP 方法
- `.and(...)` → Filter 组合（串联）
- `.or(...)` → 路由选择（并联）
- `.or_else(...)` → 错误恢复分支
- `.unify()` → 统一 Filter 输出类型
- `.boxed()` → 类型擦除
- `.recover(...)` → 错误恢复
- `.with(warp::filters::...)` → 注入共享依赖

### Poem

```rust
use poem::{Route, get, post, handler, Endpoint};

#[handler]
fn get_user(id: Path<i32>) -> Json<User> { ... }

#[handler]
fn create_user(user: Json<User>) -> Json<User> { ... }

let app = Route::new()
    .at("/users/:id", get(get_user))
    .at("/users", post(create_user))
    .nest("/api", api_routes());
```

- `.at("/path", get(handler))` / `.at("/path", post(handler))` 等
- `.nest("/prefix", router)` → 嵌套路由
- `#[handler]` 属性宏 → 将普通函数转为 Endpoint
- `impl Endpoint` trait 实现 → 手动实现端点（扫描回退策略见下）

**impl Endpoint 基本扫描回退策略**：搜索 `impl Endpoint for Xxx` 声明（含 `impl poem::Endpoint for Xxx`），提取实现该 trait 的结构体名和源文件。标注 `[ManualEndpoint: path/method not statically extractable]`。数量计入端点统计总数为低置信度（`"confidence": "low"`），等待人工确认路径和方法映射。

**跨文件 handler 追踪**：`#[handler]` 标注的函数可能定义在其他模块/文件中，通过 `use` 导入后在 `Route::new().at("/path", get(handler_name))` 中使用。搜索 handler 函数名对应的 fn 定义获取参数签名。

### 提取信息（统一 JSON 输出）
```json
{
  "endpoints": [
    {
      "method": "GET",
      "path": "/api/users/:id",
      "handler": "get_user",
      "params": ["id: i32"],
      "source": "src/handlers/user.rs",
      "framework": "axum",
      "routePrefix": "/api",
      "interfaceType": "http-server-rest",
      "confidence": "high",
      "frameworkFields": {
        "nestPrefix": "/api",
        "mountPrefix": null,
        "filterChain": null,
        "isFallback": false
      }
    },
    {
      "method": "POST",
      "path": "/users",
      "handler": "create_user",
      "params": ["user: Json<User>"],
      "source": "src/handlers/user.rs",
      "framework": "rocket",
      "routePrefix": null,
      "mountPrefix": "/",
      "interfaceType": "http-server-rest",
      "confidence": "high",
      "frameworkFields": {
        "nestPrefix": null,
        "mountPrefix": "/",
        "filterChain": null,
        "isFallback": false
      }
    },
    {
      "method": "ANY",
      "path": "/api/*rest",
      "handler": "fallback_handler",
      "params": [],
      "source": "src/routes/mod.rs",
      "framework": "axum",
      "routePrefix": "/api",
      "interfaceType": "http-server-rest",
      "confidence": "medium",
      "frameworkFields": {
        "nestPrefix": null,
        "mountPrefix": null,
        "filterChain": null,
        "isFallback": true
      }
    }
  ]
}
```

**字段说明**：
- `method`: HTTP 方法（GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/ANY）
- `path`: 完整请求路径
- `handler`: handler 函数名
- `params`: 路径参数/提取器参数列表（含类型）
- `source`: handler 定义所在源文件
- `framework`: Web 框架名（actix-web/axum/rocket/warp/poem/salvo）
- `routePrefix`: 路由路径前缀（原 `nestPrefix`，统一命名——涵盖 Axum `.nest()`、Actix `web::scope()` 和 Poem `.nest()`）
- `interfaceType`: 接口类型枚举，参照 Agent A 扩展 schema。常见值：
  - `"http-server-rest"` — 标准 REST API 端点
  - `"http-server-grpc"` — gRPC 服务（tonic）
  - `"http-server-static"` — 静态文件服务（`.nest_service()` / `ServeDir` / `FileServer`）
  - `"http-server-fallback"` — 兜底处理器
  - `"websocket-server-upgrade"` — WebSocket 升级端点
- `confidence`: 端点提取置信度（`"high"` / `"medium"` / `"low"`）
  - `"high"`: 属性宏 + 注册点均可追溯
  - `"medium"`: 跨文件函数追踪成功 / MethodRouter 变量模式
  - `"low"`: Poem `impl Endpoint` 扫描 / Warp Filter 链部分提取 / 变量引用链断裂
- `frameworkFields`: 框架特定扩展字段
  - `nestPrefix`: Axum `.nest()` / Poem `.nest()` 施加的前缀
  - `mountPrefix`: Rocket `.mount()` 施加的前缀
  - `filterChain`: Warp Filter 组合链描述（如 `"path(\"users\").and(get())"`）
  - `isFallback`: Axum `.fallback()` 兜底标识
  - `conditional`: 若路由被 cfg-gated 包裹，值为 `"<condition>"`（如 `"feature = \"gui\""`）
  - `externalRouter`: Axum 跨 crate 导入的 Router，值为 `true`

## CLI 子命令提取

### Clap (Derive API — 最常见)

```rust
#[derive(Parser)]
#[command(name = "app")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the server
    Serve {
        #[arg(short, long, default_value = "8080")]
        port: u16,
    },
    /// Run database migrations
    Migrate,
}
```

提取：
- `#[command(name = "app")]` → 应用名
- `#[command(subcommand)]` → 子命令字段
- `enum Commands` 的变体名 → 子命令名
- `/// doc comment` → 命令描述
- `#[arg(short, long, ...)]` → 选项/参数
- Clap 4.x 新属性补充：
  - `#[command(flatten)]` → 共享参数结构体——追踪被 flatten 的 struct 字段，将其参数合并到当前命令
  - `#[arg(value_enum)]` → 限定参数值为 enum 变体（自动生成可能值列表）
  - `#[arg(action = ...)]` → 参数行为（`SetTrue`/`SetFalse`/`Count`/`Append`/`Set` 等），替代旧版 `.takes_value()`
  - `#[group(...)]` → 参数组（互斥/联合约束），提取 `multiple = true`/`required = true`/`conflicts_with` 等约束

**嵌套子命令递归遍历（Derive API）**：
- 若 `#[derive(Subcommand)]` enum 变体的字段类型是另一个 `#[derive(Subcommand)]` 的 enum → 递归提取子命令并拼接路径
- 如 `enum Cmds { Serve(ServeArgs), Admin(AdminCmd) }` 且 `enum AdminCmd { Users, Logs }` → 最终命令为 `serve`、`admin users`、`admin logs`
- 在最内层子命令标注完整调用路径（如 `app serve http proxy`）

### Clap (Builder API)

```rust
let matches = Command::new("app")
    .about("A CLI application")
    .version("1.0.0")
    .subcommand(
        Command::new("serve")
            .about("Start the server")
            .arg(Arg::new("port")
                .short('p')
                .long("port")
                .value_parser(clap::value_parser!(u16))
                .default_value("8080")
                .help("Server port"))
            .arg(Arg::new("workers")
                .long("workers")
                .value_parser(clap::value_parser!(u32))
                .required(false)
                .help("Number of worker threads"))
    )
    .subcommand(Command::new("migrate").about("Run migrations"))
    .get_matches();
```

提取：
- `Command::new("name")` → 命令名
- `.about("desc")` / `.version("ver")` → 元信息
- `.subcommand(Command::new("name"))` → 子命令
- `Arg::new("name")` → 参数名
- `.short('c')` / `.long("config")` → 标志
- `.default_value("val")` → 默认值
- `value_parser!(Type)` → 类型
- `.required(true)` → 必需
- `.takes_value(true)` → 接受值
- `.help("text")` → 帮助文本
- `.get_matches()` → 解析入口

**嵌套子命令递归遍历（Builder API）**：
- 若 `.subcommand(Command::new("child"))` 内部的 Command 又调用了 `.subcommand()` → 递归提取并拼接路径
- 如 `.subcommand(Command::new("serve").subcommand(Command::new("http").subcommand(Command::new("proxy"))))` → 最终命令为 `serve http proxy`
- 在最内层子命令标注完整调用路径

**Clap 4.x Builder API 补充**：
- `.value_parser(clap::value_parser!(Type))` → 替代旧版 `.validator()` / `.parse()`
- `.action(clap::ArgAction::SetTrue)` → 替代旧版 `.takes_value(false)`
- `.num_args(1..=3)` → 替代旧版 `.number_of_values()` / `.min_values()` / `.max_values()`
- `.conflicts_with_all(["arg1", "arg2"])` → 多参数互斥约束

## 配置项提取

### 环境变量

```rust
std::env::var("DATABASE_URL")
std::env::var("PORT").unwrap_or_else(|_| "8080".into())
```

### config crate

```rust
use config::{Config, Environment};

let settings = Config::builder()
    .add_source(config::File::with_name("config/default"))
    .add_source(Environment::with_prefix("APP"))
    .build()?;
```

### .env.example

等同其他语言的提取逻辑。

### clap env 属性

```rust
#[arg(long, env = "DATABASE_URL")]
database_url: String,
```

## 项目结构

### 典型二进制项目
```
project/
├── Cargo.toml
├── src/
│   └── main.rs             # 入口
├── src/
│   ├── main.rs             # 或 bin/<name>.rs
│   ├── lib.rs              # 库代码
│   ├── config.rs          # 配置
│   ├── handlers/          # HTTP handler
│   ├── services/          # 业务逻辑
│   ├── models/            # 数据模型
│   ├── db/                # 数据库
│   └── cli/               # CLI 定义
├── migrations/
├── tests/
│   └── integration_test.rs
└── config/
    └── default.toml
```

### Workspace 结构
```
workspace/
├── Cargo.toml             # [workspace] members = [...]
├── crates/
│   ├── core/              # 核心库
│   │   ├── Cargo.toml
│   │   └── src/lib.rs
│   ├── api/               # API 服务
│   │   ├── Cargo.toml
│   │   └── src/main.rs
│   └── cli/               # CLI 工具
│       ├── Cargo.toml
│       └── src/main.rs
```

### 模块统计
- `src/` 下的 .rs 文件数（含子目录）
- Workspace members 数量
- `tests/` 测试文件数
- 公共模块（`mod` / `pub mod` 声明数）

## Rocket mount() 与 routes![] 宏

```rust
rocket::build()
    .mount("/", routes![index, health])
    .mount("/api", routes![get_user, create_user])
```

- `mount("/prefix", routes![handler1, handler2])` 是 Rocket 路由注册的核心机制
- `routes![]` 宏中的 handler 列表决定哪些端点被注册
- 属性宏（`#[get("/path")]`）只定义 handler，不注册路由
- `#[catch(code)]` 定义错误处理器，通过 `.register("/", catchers![...])` 注册
- `impl Fairing` 定义中间件，通过 `.attach(fairing)` 附加（生命周期回调：`on_ignite` / `on_liftoff` / `on_request` / `on_response` / `on_sent`）

### Rocket 端点提取三步算法

**第一步 —— 提取 mount 注册信息**：搜索 `.mount("/prefix", routes![handler1, handler2, ...])` 调用，提取：
- `mountPrefix`：mount 路径前缀（如 `"/"`、`"/api"`、`"/admin"`）
- `handlerList`：`routes![]` 宏中的 handler 函数名列表（如 `[index, health]`）

**第二步 —— 查找 handler 属性宏定义**：对第一步提取的每个 handler 函数名，跨文件搜索其路由属性宏：
- `#[get("/path")]` / `#[post("/path")]` / `#[put("/path")]` / `#[delete("/path")]` / `#[patch("/path")]` / `#[head("/path")]` / `#[options("/path")]`
- `#[route(GET, path = "/path")]`（Rocket 0.5+ 泛化形式）
- 从属性宏中提取 HTTP 方法和子路径

**第三步 —— 组装最终端点**：`最终端点路径 = mountPrefix + 子路径 + HTTP方法`
- 如 `mount("/api")` + `#[get("/users/<id>")]` → `GET /api/users/<id>`

**假阳性排除规则**：
- **仅出现在 `routes![]` 中的 handler 才是已注册端点**
- 有路由属性宏（如 `#[get("/path")]`）但未出现在任何 `routes![]` 宏中的 handler **不是端点**（编译器不报错，但 Rocket 不注册该路由）
- 搜索时应以 `routes![]` 为起点，反向查找 handler 定义，而非以属性宏为起点

**同名 handler 消歧策略**：
- **优先同文件**：在包含 `routes![]` 调用的源文件中搜索 handler 函数定义
- **其次同模块**：若同文件未找到，搜索相邻模块文件（通过 `mod` 声明图推断）
- **标注歧义**：若仍未找到或找到多个候选，标注 `[AmbiguousHandler: foo]` 并列出候选文件列表

## Warp Filter 端点提取

**基础 Filter 识别**：
- `warp::path("xxx")` → 路径段
- `warp::get()` / `warp::post()` / `warp::put()` / `warp::delete()` → HTTP 方法
- `warp::path::param::<T>()` → 路径参数（类型决定解析方式）
- `warp::path::end()` → 路径终止符
- `.and(...)` → Filter 组合（串联）
- `.or(...)` / `.or_else(...)` → 路由选择/错误恢复
- `.unify()` / `.boxed()` → 类型统一
- `.recover(...)` → 错误恢复
- `.with(filter)` → 注入共享状态

### Warp Filter 端点完整路径重建算法

**第一步 —— 识别路由分界点**：以 `.or()` 为路由分界点，每个 `.or()` 分支为独立端点候选。
```rust
let routes = get_list.or(create_user).or(get_user);
// → 三个独立端点候选
```

**第二步 —— 提取每个分支内的 Filter 链**：
- `warp::path("xxx")` → 提取路径段字面值 `"xxx"`
- `warp::path::param::<T>()` → 提取为路径参数 `{:param_name}`（类型 T 决定占位名）
- `warp::path::end()` → 标记路径终止（不再有后续段）
- `warp::get()` / `warp::post()` / `warp::put()` / `warp::delete()` / `warp::patch()` / `warp::head()` → 提取 HTTP 方法

**第三步 —— 变量引用链追踪**：
```rust
let users = warp::path("users");
let list = users.and(warp::get());
// → 追踪 users 变量定义 → warp::path("users") → 路径 = /users
```

追踪深度：2 级（直接 `let` 定义 + 一层 `let` 中转）。超过 2 级标注 `[FilterChainTruncated]`。

**重建规则**：
- 按 `.and()` 串联顺序拼接路径段：`path("api").and(path("users")).and(get())` → `GET /api/users`
- `warp::path(param)` 过滤器接受 String 参数：标注 `{param}` 为动态段
- 标注 Warp 端点提取为 `[Partial — Filter chains may be incomplete]`，confidence 为 `"medium"`

## workspace = true 依赖解析

```toml
# member Cargo.toml
[dependencies]
serde = { workspace = true }

# 根 Cargo.toml
[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
```

- `workspace = true` → 必须去根 `[workspace.dependencies]` 查找实际版本
- path / git 来源的依赖标注为特殊来源

### [workspace.package] 版本继承

```toml
# 根 Cargo.toml
[workspace.package]
version = "0.2.0"
edition = "2021"
license = "MIT"

# member Cargo.toml
[package]
name = "my-crate"
version.workspace = true
edition.workspace = true
license.workspace = true
```

- `version.workspace = true` / `edition.workspace = true` 从根 `[workspace.package]` 继承
- 需追溯根 Cargo.toml 解析实际值
- `edition.workspace = true` 解析回退：member crate 使用 `edition.workspace = true` 时，追溯根 Cargo.toml 的 `[workspace.package].edition` 获取实际 edition 值。`version.workspace = true`、`license.workspace = true`、`rust-version.workspace = true` 同理
- 若根 Cargo.toml 中 `[workspace.package]` 未定义对应字段 → 标注 `[Unresolved: <field>.workspace = true]`

### workspace.lints 继承解析（Rust 1.74+）

```toml
# 根 Cargo.toml
[workspace.lints.rust]
unsafe_code = "forbid"
missing_docs = "warn"

[workspace.lints.clippy]
all = "warn"
pedantic = "deny"

# member Cargo.toml
[lints]
workspace = true
```

- `[workspace.lints]` 定义 workspace 级别 lint 规则（含 `[workspace.lints.rust]`、`[workspace.lints.clippy]`、`[workspace.lints.rustdoc]`）
- `lints.workspace = true` 在 member crate 中继承全部 workspace lint 规则
- 提取 lint 规则名称和级别（`allow` / `warn` / `deny` / `forbid`），标注 `[WorkspaceLint]`

## optional 依赖与 feature 关联

```toml
[dependencies]
redis = { version = "0.25", optional = true }
serde_json = "1"

[features]
redis-support = ["dep:redis"]
full = ["redis-support", "tracing"]
```

- 扫描 `optional = true` 依赖 → 标注为可选
- 追踪 `[features]` 中依赖 feature 的激活关系（`dep:crate_name` 语法）

### default features 追踪

```toml
[features]
default = ["feat1", "feat2", "redis-support"]
redis-support = ["dep:redis"]
feat1 = []
feat2 = ["serde/derive"]
```

- 扫描 `[features]` 表中的 `default = ["feat1", "feat2", ...]` 行，提取默认激活的 feature 列表
- 标注：默认 feature 是项目的基础依赖范围——`default` 列表中的 feature 及其传递激活的依赖在裸 `cargo build` 时生效
- 非默认 feature 对应的 optional 依赖标注为 `[Optional: enabled via --features <name>]`
- 若无 `default` 行 → 所有 optional 依赖均需显式 `--features` 开启

## gRPC / 特殊项目类型检测

- `tonic` + `prost` → gRPC 服务（检查 `.proto` 文件和 `build.rs` 中的 `compile_protos`）
- `ratatui` + `crossterm` → TUI 终端应用
- `wasm-bindgen` + `web-sys` → WASM 前端
- `#![no_std]` + `embedded-hal` → 嵌入式/固件项目
- `bevy` → 游戏引擎
- `tauri` → 桌面应用（检查 `tauri.conf.json` / `src-tauri/`）
- `leptos` / `dioxus` / `yew` → WASM 前端框架（检查 `Trunk.toml` / `index.html` / `Cargo.toml` 的 `crate-type = ["cdylib"]`）
- `pyo3` / `maturin` → Python 绑定（检查 `pyproject.toml` 中 `build-backend = "maturin"` / `Cargo.toml` 中 `crate-type = ["cdylib"]`）
- `napi` / `napi-derive` / `neon` → Node.js 原生插件

### 特殊项目类型检测表

| 依赖名称 | 关键文件 | 检测信号 |
|---------|---------|---------|
| `tonic` + `prost` | `build.rs`, `*.proto` | `tonic_build::compile_protos()` 或 `prost_build::compile_protos()` |
| `ratatui` + `crossterm` | `src/main.rs` | `ratatui::Terminal` + `crossterm::event` |
| `wasm-bindgen` + `web-sys` | `Cargo.toml` | `crate-type = ["cdylib"]` |
| `#![no_std]` + `embedded-hal` | `src/lib.rs` / `src/main.rs` | `#![no_std]` crate 属性 + `embedded-hal` 依赖 |
| `bevy` | `src/main.rs` | `App::new().add_plugins(...)` |
| `tauri` | `tauri.conf.json`, `src-tauri/` | `tauri::Builder::default()` |
| `leptos` / `dioxus` / `yew` | `Trunk.toml` / `index.html` | `crate-type = ["cdylib"]` |
| `pyo3` / `maturin` | `pyproject.toml` | `build-backend = "maturin"` + `crate-type = ["cdylib"]` |
| `napi` / `neon` | `build.rs` | `napi_derive` proc-macro + `#[napi]` 属性 |

## 构建/安装方式

| 特征 | 安装命令 |
|------|---------|
| 标准 | `cargo build --release` / `cargo install --path .` |
| 有 `Makefile` | `make build`（见下方 Makefile 提取） |
| 有 `justfile` | `just build`（见下方 justfile 提取） |
| 发布到 crates.io | `cargo install <crate-name>` |
| Docker | `docker build` |
| Tauri | `cargo tauri build` |
| Pyo3/Maturin | `maturin build --release` / `pip install .` |

### Makefile target 提取

参照 Go scanner 格式：
- 扫描 `.PHONY:` 声明 → 提取伪目标名列表
- 扫描 `目标名:` 行 → 提取所有无歧义的 target 名（过滤 `.o`/`.d`/`%/` 等隐式规则）
- 常见 Rust 项目 target：`build`、`release`、`test`、`lint`、`fmt`、`clean`、`run`、`watch`、`doc`
- 过滤项：忽略 `.cargo/config.toml` 别名

### justfile recipe 提取

参照 Go scanner 格式：
- 扫描 `recipe名:` 行 → 提取 recipe 名称
- 扫描 `# 注释` → 提取 recipe 描述（紧邻 recipe 上方的注释行）
- 常见 Rust 项目 recipe：`build`、`release`、`test`、`lint`、`fmt`、`clean`、`run`、`watch`、`doc`
- 提取 recipe 名称和描述，标注为 `[Recipe: <name>]`

## Edition 版本

从 `Cargo.toml` 提取 `edition` 字段（2015 / 2018 / 2021 / 2024），用于了解项目使用的 Rust 版本。

## 未覆盖场景（已知限制）

- `argh` / `lexopt` / `bpaf` CLI 框架：子命令提取不支持
- Cargo `crate-type = ["cdylib"]` 等动态/静态库类型：不区分子类型
- proc-macro crate：不提取宏定义
- `extern "C"` FFI 函数导出：不提取对外 C API
- optional 依赖的 feature 关联仅追踪同文件 `[features]` 声明，不跨 workspace member 追溯
- Warp Filter `.boxed()` 类型擦除后：Filter 链追踪终止
- Rocket 0.5+ 自定义路由阶段（`AdHoc` / `manage` / `ignite` 自定义）不追踪

## cfg-gated 路由标注

```rust
#[cfg(feature = "gui")]
#[get("/dashboard")]
fn dashboard() -> Html<String> { ... }
```

```rust
#[cfg(unix)]
mod unix_handlers {
    #[get("/unix-only")]
    fn handler() -> &'static str { ... }
}
```

- 若路由注册代码（handler 定义或 `.route()`/`.mount()`）被 `#[cfg(...)]` 包裹 → 标注该路由为 `[Conditional: <condition>]`（如 `[Conditional: feature = "gui"]`、`[Conditional: unix]`）
- 关联 `[features]` 表判断 cfg-feature 的默认激活状态：若 feature 在 `default` 列表中 → 默认生效；否则需 `--features <name>` 手动激活
- cfg 条件解析：识别 `any()` / `all()` / `not()` 组合条件，提取原始条件表达式字符串
- `cfg(test)` 包裹的路由仅测试环境可见，标注 `[TestOnly]` 不计入生产端点计数