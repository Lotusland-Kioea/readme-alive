# Go 扫描规则

## 检测条件

**主要**：
- 存在 `go.mod` 文件

**子类型判断**：
- 含 `github.com/gin-gonic/gin` → Gin Web 框架
- 含 `github.com/labstack/echo` → Echo Web 框架
- 含 `github.com/gofiber/fiber` → Fiber Web 框架
- 含 `github.com/gorilla/mux` → Gorilla Mux 路由
- 含 `github.com/go-chi/chi/v5` → Chi 路由
- 含 `github.com/spf13/cobra` → CLI 工具（Cobra）
- 含 `github.com/urfave/cli` → CLI 工具（urfave）
- 只有 `main.go` 在根目录 → 简单应用/CLI
- `cmd/` 下有多个子目录 → 多命令 CLI

## 技术栈提取

### go.mod

```
module github.com/user/project

go 1.21

require (
    github.com/gin-gonic/gin v1.9.1
    github.com/redis/go-redis/v9 v9.3.0
)

require (
    github.com/bytedance/sonic v1.9.1 // indirect
    ...
)
```

提取：
- Go 版本（`go 1.21`）
- 直接依赖：扫描所有 `require` 块中的所有行，排除行尾匹配 `//\s*indirect` 的条目（允许 `// indirect` 和 `//indirect` 等空白变体）。**不要按 require 块的位置判断**——正确做法见下方"依赖解析修正"章节。
- `replace` 指令应被提取用于版本覆盖识别

重点关注的依赖类别：
- Web 框架：gin, echo, fiber, gorilla/mux, chi, net/http
- 数据库：gorm, sqlx, pgx, go-sql-driver/mysql, sqlite3
- 缓存：go-redis, bigcache, freecache
- 消息队列：kafka-go, sarama, amqp
- 配置：viper, envconfig, koanf
- CLI：cobra, urfave/cli, kingpin（检测但不提取）
- 测试：testify, ginkgo, go-sqlmock
- DI：wire, fx
- 工具：zap, zerolog, logrus

## API 端点提取

### Gin

```go
func setupRouter() *gin.Engine {
    r := gin.Default()
    r.GET("/users/:id", getUser)
    r.POST("/users", createUser)
    r.PUT("/users/:id", updateUser)
    r.DELETE("/users/:id", deleteUser)
    return r
}
```

覆盖方法包括：GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS（及框架特定的 Any/All/Handle 等通用注册形式）。

扫描模式：
- `r.GET("/path", handler)` / `r.POST(...)` / `r.PUT(...)` / `r.DELETE(...)` / `r.PATCH(...)` / `r.HEAD(...)` / `r.OPTIONS(...)`
- `r.Handle("METHOD", "/path", handler)` — 通用方法注册
- `r.Any("/path", handler)` — 匹配所有 HTTP 方法
- `r.Static("/assets", "./public")` / `r.StaticFile("/favicon.ico", "./favicon.ico")` / `r.StaticFS("/static", http.Dir("./static"))` — 静态文件服务
- `router.Group("/prefix")` → 前缀 + 子路由路径

**Group 嵌套路由前缀聚合**：
```go
api := r.Group("/api")
v1 := api.Group("/v1")
v1.GET("/users", handler)  // 最终路径: /api/v1/users
```
- Group 链追踪：递归收集 Group 前缀，按注册顺序拼接完整路径前缀
- 跨函数 Group 引用：搜索返回 `*gin.RouterGroup` 或接收 `*gin.RouterGroup` 参数的函数
- 中间件：`r.Use(middleware)` / `group.Use(middleware)` 提取中间件链

### Echo

```go
e := echo.New()
e.GET("/users/:id", getUser)
e.POST("/users", createUser)
api := e.Group("/api")
v1 := api.Group("/v1")
v1.GET("/users", handler)  // /api/v1/users
```

覆盖方法包括：GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/CONNECT/TRACE（及框架特定的 Any/All/Handle 等通用注册形式）。

- `e.GET(...)` / `e.POST(...)` / `e.PUT(...)` / `e.DELETE(...)` / `e.PATCH(...)` / `e.HEAD(...)` / `e.OPTIONS(...)` / `e.CONNECT(...)` / `e.TRACE(...)`
- `e.Any("/path", handler)` — 匹配所有 HTTP 方法
- `e.Match([]string{"GET", "POST"}, "/path", handler)` — 多方法注册
- `e.Add("GET", "/path", handler)` — 通用方法注册（同 Handle）
- `e.Static("/static", "public")` / `e.File("/favicon.ico", "favicon.ico")` — 静态文件服务
- Group 嵌套前缀聚合同 Gin 算法
- 中间件：`e.Use(middleware)` / `group.Use(middleware)`

### Fiber

```go
app := fiber.New()
app.Get("/users/:id", getUser)
app.Post("/users", createUser)
api := app.Group("/api")
v1 := api.Group("/v1")
v1.Get("/users", handler)  // /api/v1/users
```

覆盖方法包括：GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/CONNECT/TRACE（及框架特定的 All 等通用注册形式）。

- `app.Get(...)` / `app.Post(...)` / `app.Put(...)` / `app.Delete(...)` / `app.Patch(...)` / `app.Head(...)` / `app.Options(...)` / `app.Connect(...)` / `app.Trace(...)`
- `app.All("/path", handler)` — 匹配所有 HTTP 方法
- `app.Use("/prefix", middleware)` — 路径前缀中间件
- Group 嵌套前缀聚合同 Gin 算法
- 中间件：`app.Use(middleware)` / `group.Use(middleware)`

### Chi

```go
r := chi.NewRouter()
r.Get("/users/{id}", getUser)
r.Post("/users", createUser)

// 嵌套路由组
r.Route("/api", func(r chi.Router) {
    r.Route("/v1", func(r chi.Router) {
        r.Get("/users", listUsers)
        r.Post("/users", createUser)
    })
})

// 子路由挂载
r.Mount("/admin", adminRouter)

// 中间件
r.Use(middleware.Logger)
r.With(middleware.Auth).Get("/me", getMe)
```

覆盖方法包括：GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS/CONNECT/TRACE（及框架特定的 Handle/HandleFunc 等通用注册形式）。

扫描模式：
- `r.Get("/path", handler)` / `r.Post(...)` / `r.Put(...)` / `r.Delete(...)` / `r.Patch(...)` / `r.Head(...)` / `r.Options(...)` / `r.Connect(...)` / `r.Trace(...)`
- `r.Handle("METHOD", "/path", handler)` / `r.HandleFunc("METHOD /path", handler)` — 通用方法注册
- `r.Route("/prefix", func(r chi.Router) {...})` → 嵌套路由组（匿名函数内递归扫描）
- `r.Use(middleware)` → 全局中间件
- `r.With(middleware1, middleware2).Get("/path", handler)` → 路由级中间件
- `r.Mount("/prefix", subRouter)` → 子路由挂载

**Route 闭包追踪提示**：Route 闭包内的 `r` 参数类型为 `chi.Router`（接口），其可调用的路由注册方法与外层 `*chi.Mux` 一致。跨闭包追踪时需注意变量遮蔽——内层闭包重新声明 `r` 后，外层路由变量不可见。每层闭包需独立解析 `r` 的引用范围。

### Gorilla Mux

```go
r := mux.NewRouter()
r.HandleFunc("/users/{id:[0-9]+}", getUser).Methods("GET")
r.HandleFunc("/users", createUser).Methods("POST")
r.HandleFunc("/users/{id}", updateUser).Methods("PUT")
r.HandleFunc("/users/{id}", deleteUser).Methods("DELETE")

// 子路由前缀
api := r.PathPrefix("/api").Subrouter()
v1 := api.PathPrefix("/v1").Subrouter()
v1.HandleFunc("/users", listUsers).Methods("GET")  // 最终路径: /api/v1/users

// 中间件
r.Use(loggingMiddleware)
api.Use(authMiddleware)

// 路由级中间件（方法链）
r.Methods("GET").Subrouter().Use(middleware).HandleFunc("/secure", handler)

// 路径前缀挂载
r.PathPrefix("/admin").Handler(adminRouter)
```

覆盖方法包括：GET/POST/PUT/DELETE/PATCH/HEAD/OPTIONS（及 `Methods()` 通用注册形式）。

扫描模式：
- `r.HandleFunc("/path", handler).Methods("GET", "POST")` — 端点提取；方法取自 Methods 参数
- `r.Handle("/path", http.HandlerFunc(handler)).Methods("DELETE")` — Handler 接口形式
- `r.PathPrefix("/prefix").Subrouter()` — 子路由前缀聚合：递归追踪 PathPrefix 链，按注册顺序拼接完整路径前缀（与 Gin Group 前缀聚合算法相同）
- `r.Path("/fixed").Handler(handler)` — 精确路径注册
- `r.Use(middleware)` — 全局中间件
- `r.NewRoute().Path("/path").Handler(handler)` — 流式构建
- `subrouter.Use(middleware)` — 子路由级别中间件

**URL 变量识别**：
- `{id}` — 无约束变量
- `{id:[0-9]+}` — 正则约束变量（gorilla/mux 特有）
- `{slug:[a-z-]+}` — 自定义正则变量
- 输出时统一映射为 JSON endpoint schema 中的路径参数（提取变量名和正则约束）

### 标准库 net/http

```go
// 传统模式（所有 Go 版本）
http.HandleFunc("/users", usersHandler)
http.Handle("/path", &myHandler{})

// Go 1.22+ 增强路由（方法前缀 + 路径参数）
mux := http.NewServeMux()
mux.HandleFunc("GET /users/{id}", getUser)     // HandleFunc 支持 METHOD 前缀
mux.HandleFunc("POST /users", createUser)
mux.Handle("GET /users/{id}", myHandler)       // Handle 同样支持 METHOD 前缀
mux.Handle("PUT /users/{id}", anotherHandler)

// 自定义 Handler 接口
type myHandler struct{}
func (h *myHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) { ... }
```

**Go 1.22+ 增强注意**：
- Go 1.22+ 默认 ServeMux 支持方法前缀和路径参数模式，`http.HandleFunc("METHOD /path", handler)` 和 `http.Handle("METHOD /path", handler)` 均有效。
- 路径参数语法：`{name}` 匹配单个路径段，`{$}` 匹配路径尾部。
- 通过 go.mod 中的 `go 1.22`（或更高）判断项目是否启用增强模式——`go` 指令版本控制语言特性开关。

### 提取信息（统一 JSON 输出）
```json
{
  "endpoints": [
    {
      "method": "GET",
      "path": "/api/v1/users/{id}",
      "handler": "getUser",
      "middleware": ["auth", "logger"],
      "source": "handlers/user.go",
      "framework": "gin"
    }
  ]
}
```

**Handler 定位策略**：由于 Go 无注解，路由定义可能在函数体内。建议搜索返回 `*gin.Engine` / `*echo.Echo` / `*fiber.App` / `*chi.Mux` 的函数或以其为参数的 Setup 函数来缩小扫描范围。

## CLI 子命令提取

### Cobra

```go
var rootCmd = &cobra.Command{Use: "app"}
var serveCmd = &cobra.Command{Use: "serve", Short: "Start server", Run: ...}
var migrateCmd = &cobra.Command{Use: "migrate", Run: ...}
rootCmd.AddCommand(serveCmd, migrateCmd)
```

提取：
- `&cobra.Command{Use: "command-name"}` → 子命令名
- `Short:` / `Long:` → 命令描述
- `Flags()` / `PersistentFlags()` 调用 → 选项/参数
- 生命周期钩子函数引用：
  - `PersistentPreRun:` / `PersistentPreRunE:` — 当前命令及所有子命令执行前（常用于全局初始化）
  - `PreRun:` / `PreRunE:` — 当前命令执行前
  - `Run:` / `RunE:` — 命令主执行函数
  - `PostRun:` / `PostRunE:` — 当前命令执行后
  - `PersistentPostRun:` / `PersistentPostRunE:` — 当前命令及所有子命令执行后
  - 钩子函数名提取后可反向定位函数定义，展示命令的执行流程

**嵌套子命令递归遍历**：
```go
rootCmd.AddCommand(serveCmd)
serveCmd.AddCommand(httpCmd)
httpCmd.AddCommand(proxyCmd)  // app serve http proxy
```
- 构建 Command → AddCommand 的父子关系图
- 递归遍历 `AddCommand` 调用链，拼接完整命令路径（如 `app serve http proxy`）
- 每层提取对应 Command 的 Use/Short/Long/Flags

### urfave/cli

**v2 vs v3 API 区分**：通过 go.mod 依赖路径判断：
- `github.com/urfave/cli/v2` → v2 API（`app.Commands` 切片 / `cli.Command` 结构体）
- `github.com/urfave/cli/v3` → v3 API（函数式 `&cli.Command{}.Commands()` 方法）

**v2 提取模式**：
```go
app.Commands = []*cli.Command{
    {
        Name:    "serve",
        Aliases: []string{"s"},
        Usage:   "Start server",
        Flags: []cli.Flag{...},
        Subcommands: []*cli.Command{
            {Name: "http", Usage: "Start HTTP server"},
        },
    },
    {Name: "migrate", Usage: "Run migrations"},
}
```
- `Name` / `Aliases` / `Usage` / `UsageText` → 命令标识和帮助信息
- `Flags` → 选项/参数（提取 Name 和对应的 EnvVars/Target）
- `Subcommands` → 嵌套子命令（递归遍历，拼接完整命令路径如 `app serve http`）
- `Action` → 命令执行函数引用（用于反向定位执行逻辑）

**v3 提取模式**：
```go
(&cli.Command{Name: "serve", Usage: "Start server"}).Commands(
    &cli.Command{Name: "http", Usage: "Start HTTP server"},
)
```
- 通过 `.Commands()` 方法链构建嵌套子命令
- Flags/Aliases/UsageText 提取逻辑与 v2 一致

**通用提示**：子命令嵌套不限深度，递归遍历所有 Subcommands/Commands() 调用链，每层提取 Name/Aliases/Usage/Flags/Action。

## 配置项提取

### Viper

```go
viper.GetString("server.port")
viper.GetInt("database.max_conns")
viper.BindEnv("redis.url", "REDIS_URL")
```

### 环境变量直接读取

```go
os.Getenv("PORT")
os.Getenv("DATABASE_URL")
```

### .env.example

按行解析 `key=value` 格式，忽略空行和以 `#` 开头的注释行。提取规则：
- 提取所有 key 形成变量列表
- `KEY=value` → key 有默认值（记录 value 作为默认值）
- `KEY=` → key 存在但无默认值（需用户填写）
- `KEY=${NESTED_REF}` → 变量引用（追踪引用的目标变量）
- 输出 JSON schema：`{"variable": "PORT", "default": "8080", "required": false}`

### 配置文件

- `config.yaml` / `config.yml` → 提取顶级 key
- `config.toml` → 提取顶级 section

## 项目结构

### 标准 Go 项目布局
```
project/
├── main.go              # 或 cmd/<app>/main.go
├── cmd/                 # 多命令入口
│   ├── server/
│   └── worker/
├── internal/            # 私有包
│   ├── handler/         # HTTP handler
│   ├── service/         # 业务逻辑
│   ├── repository/      # 数据访问
│   └── model/           # 数据模型
├── pkg/                 # 可暴露的公共包
├── api/                 # API 定义（OpenAPI/Proto）
├── config/              # 配置加载
├── migrations/          # 数据库迁移
├── go.mod
└── go.sum
```

### 模块统计
- `cmd/` 下的入口数量
- `internal/` 下的子包数
- `pkg/` 下的子包数
- 总计 .go 文件数（排除 vendor/ 和 testdata/）

## 依赖解析修正

### go.mod require 块解析

**不要按第几个 block 判断直接/间接依赖！** 正确做法：
- 扫描所有 `require` 块中的所有行
- 排除行尾匹配 `//\s*indirect` 的条目（允许 `// indirect` 和 `//indirect` 等空白变体）
- `replace` 指令应被提取用于版本覆盖识别

### go.work 支持

```go
go 1.21

use (
    ./services/user
    ./services/order
    ./libs/common
)
```

- 检测 `go.work` → Go Workspace Monorepo
- 遍历 `use` 指令指向的子目录中的 `go.mod`
- 每个子模块独立评估类型（Web/CLI/库）
- **replace 指令**：go.work 中的 `replace` 影响所有 use 子模块（与 go.mod replace 行为不同），需独立提取
- **go.work.sum**：检测并校验 workspace 级依赖完整性
- **toolchain 指令**：Go 1.21+ 的 `toolchain go1.22.0` 声明
- **exclude 指令**：Go 1.24+ 支持在 go.work 中使用 `exclude` 指令排除特定模块版本（与 go.mod exclude 行为类似，但影响范围覆盖所有 use 子模块）
- **环境变量参考**：`GONOSUMCHECK` / `GONOSUMDB` / `GOPRIVATE` / `GOFLAGS` / `GOTOOLCHAIN` 配置
  - `GOTOOLCHAIN`：Go 1.21+ 引入，控制 toolchain 自动下载行为（`local` 仅用本地版本，`auto` 默认自动获取，`path` 从指定路径加载）

## gRPC 服务定义提取

```protobuf
// proto/user.proto
service UserService {
    rpc GetUser (GetUserRequest) returns (User);
    rpc ListUsers (ListUsersRequest) returns (ListUsersResponse);
}
```

- 扫描 `.proto` 文件中的 `service` 定义和 `rpc` 方法
- 扫描 Go 代码中 `pb.Register*Server(grpcServer, impl)` 调用
- 识别 `google.golang.org/grpc` 依赖

## 依赖注入框架

### wire
```go
// wire.go
//go:build wireinject

func InitializeUserService() *UserService {
    wire.Build(NewDB, NewUserRepo, NewUserService)
    return nil
}
```
- 检测 `wire.go` / `wire_gen.go` 文件
- 提取 `wire.Build()`（Provider Set）和 `wire.NewSet()` 定义的依赖关系
- 高级特性（简要说明）：
  - `wire.FieldsOf(new(T), "Field1", "Field2")` — 从结构体提取字段作为 provider
  - `wire.Bind(new(Interface), new(Impl))` — 接口绑定（接口类型到实现类型的映射）
  - `wire.Struct(new(T), "Field1", "Field2")` — 结构体注入（字段名对应已有 provider）
  - `wire.Value(myVar)` — 值注入（将运行时变量直接注入为 provider）
  - `wire.InterfaceValue(new(MyInterface), myImpl)` — 接口值绑定

### fx（Uber）
```go
fx.New(
    fx.Provide(NewDB, NewUserRepo, NewUserService),
    fx.Invoke(StartServer),
).Run()
```
- 提取 `fx.Provide()` 构造函数列表
- 提取 `fx.Invoke()` 启动函数
- 识别 `fx.Module()` 模块化组织

## 数据库迁移工具

| 工具 | 检测信号 | 迁移文件格式 |
|------|---------|-------------|
| golang-migrate | `github.com/golang-migrate/migrate/v4` 依赖 | `{version}_{title}.up.sql` / `{version}_{title}.down.sql` |
| goose | `github.com/pressly/goose/v3` 依赖 | `{version}_{title}.go` 或 `.sql` |
| atlas | `atlas.sum` 文件 | `atlas.hcl` 配置 |

## OpenAPI/Swagger（swag 注解）

```go
// @title          User Service API
// @version        1.0
// @description    This is a user management service.
// @host           localhost:8080
// @BasePath       /api/v1
func main() { ... }

// @Router /users/{id} [get]
// @Summary Get user by ID
// @Param id path int true "User ID"
func getUser(c *gin.Context) { ... }
```

- 全局注解：`@title` / `@version` / `@description` / `@host` / `@BasePath` / `@schemes` / `@securityDefinitions`
- 端点注解：`@Router /path [method]` / `@Summary` / `@Param`

## 代码生成检测（go:generate）

```go
//go:generate stringer -type=Status
//go:generate mockgen -source=interface.go -destination=mock.go
```

扫描 `//go:generate` 指令，识别常见工具：

| 指令前缀 | 工具 | go.mod 依赖路径 | 用途 |
|---------|------|---------------|------|
| `stringer` | golang.org/x/tools/cmd/stringer | `golang.org/x/tools` | 枚举 String() 方法 |
| `mockgen` | github.com/golang/mock | `github.com/golang/mock` | Mock 生成 |
| `mockery` | github.com/vektra/mockery | `github.com/vektra/mockery/v2` | 接口 Mock 自动生成 |
| `counterfeiter` | github.com/maxbrunsfeld/counterfeiter | `github.com/maxbrunsfeld/counterfeiter/v6` | 接口 Fake 实现生成 |
| `protoc-gen-go` | protobuf | `google.golang.org/protobuf` | Proto 代码生成 |
| `protoc-gen-go-grpc` | gRPC proto | `google.golang.org/grpc` | gRPC 服务端/客户端代码生成 |
| `swag init` | github.com/swaggo/swag | `github.com/swaggo/swag` | Swagger 文档生成 |
| `wire` | github.com/google/wire | `github.com/google/wire` | DI 代码生成 |
| `ent` | entgo.io/ent | `entgo.io/ent` | ORM Schema 代码生成 |
| `sqlc` | github.com/sqlc-dev/sqlc | `github.com/sqlc-dev/sqlc` | SQL 优先的 Go 代码生成 |
| `oapi-codegen` | github.com/oapi-codegen/oapi-codegen | `github.com/oapi-codegen/oapi-codegen/v2` | OpenAPI 客户端/服务端代码生成 |
| `buf generate` | github.com/bufbuild/buf | `github.com/bufbuild/buf` | Protobuf 统一代码生成（替代 protoc） |
| `gqlgen` | github.com/99designs/gqlgen | `github.com/99designs/gqlgen` | GraphQL 服务端代码生成 |
| `go run` | (通用自定义生成器) | (视项目而定) | 执行 Go 程序作为代码生成器（常用于项目定制生成逻辑） |

## 跨平台构建标签

```go
//go:build linux
//go:build windows && amd64
```

- 扫描 `//go:build` 约束行，提取平台和架构限制
- 识别文件名约定：`*_linux.go` / `*_windows.go` / `*_darwin.go` / `*_amd64.go` / `*_arm64.go` 等
- **旧式 `// +build` 语法**：早期 Go（Go 1.17 之前）使用空格/逗号分隔的 `// +build` 约束（如 `// +build linux amd64`）。旧项目可能两种语法并存（`// +build` 在 `//go:build` 上面），需识别两种语法并提取等效约束条件。

## 嵌入资源（go:embed）

```go
//go:embed templates/*
var templates embed.FS

//go:embed config/default.yaml
var defaultConfig []byte
```

- 扫描 `//go:embed` 指令路径
- 提取嵌入的文件、目录、通配模式
- 记录变量类型（`embed.FS` / `string` / `[]byte`）

## 依赖解析修正（续）

### go.sum 校验
- `go.sum` 存在性检测
- 间接依赖提取算法（集合运算伪代码）：

```
// 定义集合
A = go.sum 中所有模块条目的集合（module@version）
B = go.mod 所有 require 块中模块的集合（无论是否标记 // indirect）
C = go.mod 所有 replace 指令中旧模块的集合（被替换的模块）

// 计算间接依赖
间接依赖 = A - B - C

// 步骤说明：
// 1. 解析 go.sum → 提取所有 "module version h1:hash" 条目 → 得到集合 A
// 2. 解析 go.mod → 提取 require 块中所有行（含 // indirect 和未标记的） → 模块加入集合 B
// 3. 解析 go.mod → 提取 replace 指令中被替换的模块（'old' 部分） → 模块加入集合 C
// 4. 集合差：A ∖ (B ∪ C) → 剩余的模块即为间接依赖
// 5. 将间接依赖按 module@version 格式输出，兼容统一 JSON dependency schema
```

### 多 go.mod 无 go.work 场景
- 检测多个 go.mod 文件但无 go.work → 报告"检测到多个模块但无 go.work，建议迁移"
- 通过 `replace` 指令手动连接的本地模块需单独识别

### GOPATH 模式
GOPATH 项目（无 go.mod）完全无法通过模块检测。缓解信号：

| 信号 | 说明 |
|------|------|
| `vendor/` 目录 | 遗留 vendor 管理 |
| `Gopkg.toml` | dep 依赖管理 |
| `glide.yaml` | Glide 依赖管理 |
| `Godeps/` | godep 依赖管理 |

检测到以上信号时标注为遗留 Go 项目并建议迁移到 go modules。

## 构建/安装方式

| 文件 | 方式 |
|------|------|
| `Makefile` | `make build` / `make install`。提取有效 target：优先解析 `.PHONY` 声明中的目标列表（make 惯用法中 `.PHONY` 列出所有用户可见 target），再补充匹配冒号行：`grep -E '^[a-zA-Z0-9_./%-]+:' Makefile | grep -v ':='`。此正则扩展了数字 `[0-9]`、点 `.`、斜杠 `/`、百分号 `%` 和短横线 `-`，并用 `grep -v ':='` 排除变量赋值误匹配。 |
| `Taskfile.yml` | Task runner |
| `magefile.go` | Mage 构建工具 |
| `BUILD` / `WORKSPACE` | Bazel 构建 |
| `.goreleaser.yml` | GoReleaser 发布构建 |
| `justfile` | Just 命令执行器 |
| `docker-compose.yml` | Docker Compose。提取内容：`services` 下各服务名、`ports` 端口映射、`environment` 环境变量（含 `env_file` 引用）、`depends_on` 服务依赖关系、`build.context` 构建上下文路径、`volumes` 挂载映射、`networks` 网络配置。 |
| 无构建文件 | `go build ./...` / `go install ./...` |
| `Dockerfile` | Docker 构建 |

用于更新 README 中的构建/安装命令。

## 未覆盖场景（已知限制）

- Beego / Iris / Revel 等非主流 Web 框架：未被子类型识别
- Kong / argh / kingpin CLI 框架：CLI 子命令提取不支持
- Go 标准库使用（net/http, database/sql）：不体现在技术栈中
- GOPATH 模式项目（无 go.mod）：完全无法通过模块检测（仅有信号识别）
- `ent` / `bun` ORM、`gqlgen` GraphQL 等依赖未被列入重点类别
- Chi 跨包 Router 传播：子路由定义在独立包中时，跨包追踪可能失败
- go.work replace 仅提取本地路径替换关系，不验证替换目标是否存在
- Cobra 命令的 `TraverseChildren` 模式下的参数传递关系不追踪
- swag 注解的动态描述（模板变量）不解析
- go:generate 依赖的工具未安装时无法验证指令有效性
- 构建标签不评估矩阵组合（如 `linux && (amd64 || arm64)`）