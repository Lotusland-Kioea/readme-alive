# Java / Spring Boot 扫描规则

## 检测条件

**主要**：
- 存在 `pom.xml` 且包含 `<parent>` 中 `spring-boot-starter-parent`
- 存在 `src/main/java/` 目录

**多模块 Maven 项目**：
- 若 `pom.xml` 含 `<modules>` 且 `<packaging>pom</packaging>` → 识别为多模块根 POM
- 遍历 `<module>` 子目录，检查子 POM 的 `<parent>` 链追溯 `spring-boot-starter-parent`
- 子模块须同时具备 `src/main/java/` 才算 Spring Boot 模块

**兜底**：
- 存在 `build.gradle` 或 `build.gradle.kts` 且包含 `spring-boot` 插件
- 存在 `pom.xml` + `spring-boot-dependencies` 作为 BOM import（检查 `<type>pom</type>` + `<scope>import</scope>`）
- 存在 `pom.xml` + `spring-boot-maven-plugin` 作为构建插件
- 存在 `src/main/java/` 目录
- 存在 `src/main/resources/application.yml` 或 `application.properties` → 弱信号辅助判定 Spring Boot

## 技术栈提取

### Maven（pom.xml）

从 `<dependencies>` 中提取关键依赖。

**依赖版本解析（两阶段模型）**：

**阶段A：版本来源查找**（优先级从高到低，命中即停止）：
1. `<dependencies>` 中显式 `<version>`（最高优先级，直接声明版本）
2. 当前 POM `<dependencyManagement>` 中声明的版本
3. 直接 parent POM `<dependencyManagement>`
4. scope=import BOM 传递版本（`<type>pom</type>` + `<scope>import</scope>`）

**阶段B：占位符插值**：对阶段A找到的版本字符串中的 `${xxx}`，依次从以下源解析：
1. 当前 POM `<properties>`
2. 直接 parent `<properties>`
3. scope=import BOM 的 `<properties>`

> **限制**：仅解析直接 parent，不递归追溯祖父 parent（已知限制）。`settings.xml` / `-D` 系统属性为运行时覆盖，不可追溯。

```
groupId:artifactId → 版本按上述两阶段模型解析
```

重点关注：
- spring-boot-starter-* 系列
- 数据库驱动（mysql-connector, postgresql, h2）
- ORM 框架（mybatis-plus, hibernate, jpa）
- 缓存（redis, caffeine）
- 消息队列（kafka, rabbitmq, rocketmq）
- 安全（spring-security, shiro）
- 工具库（lombok, mapstruct, hutool）

**通用判定规则**（在枚举清单之后追加，确保未列举的依赖也能被覆盖）：
- artifactId 以 `spring-boot-starter-` 开头 → 始终提取
- groupId 以 `org.springframework.cloud`、`io.micrometer`、`org.apache.kafka`、`com.alibaba.cloud`、`org.mybatis.spring.boot`、`org.apache.shardingsphere` 等常见中间件组织开头 → 提取
- artifactId 匹配 `*-connector`、`*-driver`、`*-client`、`*-starter` → 提取
- scope=test 的依赖排除
- `spring-boot-devtools` 排除
- 兜底规则："如有疑问，提取"以偏好召回

### Gradle

从 `dependencies` 块提取依赖。

**配置类型区分**：
- `implementation` → 运行时依赖（默认）
- `api` → 暴露给消费者的编译依赖
- `compileOnly` → 仅编译时（如 lombok）
- `runtimeOnly` → 仅运行时（如数据库驱动）
- `annotationProcessor` → 注解处理器
- `testImplementation` / `testCompileOnly` / `testRuntimeOnly` → 测试作用域（仅记录存在性，不纳入主技术栈）

**版本来源优先级**（按顺序查找）：
1. 依赖声明中直接指定的版本号
2. `ext {}` 块中的变量（Groovy DSL）：`ext { springVersion = '3.2.0' }`
3. `libs.versions.toml` Gradle Version Catalog（解析 `[versions]` 节）
4. `implementation(platform(...))` BOM 导入传递版本
5. `buildscript { dependencies { ... } }` classpath 版本（如 Spring Boot 插件管理的版本）

**Kotlin DSL vs Groovy DSL 语法差异**：
- Groovy：`implementation 'group:artifact:version'`
- Kotlin：`implementation("group:artifact:version")`
- Groovy：`ext { set('springVersion', '3.2.0') }`
- Kotlin：`extra["springVersion"] = "3.2.0"`

**BOM 导入检测**：
```groovy
// Groovy DSL
implementation platform('org.springframework.boot:spring-boot-dependencies:3.2.0')

// Kotlin DSL
implementation(platform("org.springframework.boot:spring-boot-dependencies:3.2.0"))
```

## API 端点提取

扫描以下注解标记的类和方法：

### 控制器识别
- `@RestController`
- `@Controller`

### 路由提取
- 类级别：`@RequestMapping("/path")`
- 方法级别：`@GetMapping`, `@PostMapping`, `@PutMapping`, `@DeleteMapping`, `@PatchMapping`, `@RequestMapping`

### 提取信息
- HTTP 方法 + 完整路径（类路径 + 方法路径）
- 方法签名参数（请求体类型、路径变量、请求参数）
- 返回类型
- 方法和类的 JavaDoc 注释（如果有）
- 方法和方法所在类的 JavaDoc 注释（如果有）

### 示例输出
```json
{
  "endpoints": [
    {
      "method": "GET",
      "path": "/api/users/{id}",
      "params": ["Long id"],
      "returnType": "ApiResponse<UserVO>",
      "javadoc": "根据ID查询用户"
    }
  ]
}
```

### OpenAPI 注解提取（可选增强）

当检测到 `io.swagger.v3.oas.annotations` 或 `io.swagger.core.v3` 系列依赖时，从控制器方法上提取以下注解信息：
- `@Operation(summary = "xxx", description = "xxx")` → 接口摘要与描述
- `@ApiResponse(responseCode = "200", description = "xxx")` → 响应说明
- `@Tag(name = "xxx")` → 接口分组标签
- `@Parameter(description = "xxx", required = true)` → 参数说明

提取的 OpenAPI 元数据作为端点对象的可选字段附加（`summary`、`description`、`tags`、`responses`）。

## 配置项提取

从以下文件提取关键配置：

### application.yml / application.properties
- `server.port`
- `spring.datasource.url`, `spring.datasource.username`（脱敏）
- `spring.profiles.active`
- `spring.redis.host`, `spring.redis.port`
- `spring.kafka.bootstrap-servers`

### application-{profile}.yml
- 识别所有 profile 文件
- 提取每个 profile 的差异配置

### application.yml 多文档解析
Spring Boot 支持在单个 YAML 文件中使用 `---` 分隔符定义多个文档：
```yaml
spring:
  profiles:
    active: dev
---
spring:
  profiles: dev
server:
  port: 8080
---
spring:
  profiles: prod
server:
  port: 8443
```
扫描规则：
- 识别 `---` 分隔符，拆分多文档
- 提取每个文档的 `spring.profiles`（或 `spring.config.activate.on-profile`）
- 分别记录每个 profile 文档中的配置项

### bootstrap.yml / bootstrap.properties 检测
Spring Cloud 引导配置文件，在应用主配置之前加载：
- 检测 `bootstrap.yml` / `bootstrap.properties` 文件存在性
- 提取 `spring.application.name`
- 提取 `spring.cloud.config.uri`、`spring.cloud.nacos.*`、`spring.cloud.consul.*`

### WebSocket / STOMP 端点
```java
@MessageMapping("/chat.send")
@SendTo("/topic/public")
public ChatMessage sendMessage(ChatMessage message) { ... }

@SubscribeMapping("/user/queue/notifications")
public List<Notification> subscribeNotifications() { ... }
```
扫描 `@MessageMapping`、`@SendTo`、`@SubscribeMapping` 注解，检查 `@EnableWebSocketMessageBroker` 配置类。

### Spring Data REST 自动端点
`@RepositoryRestResource(collectionResourceRel = "users", path = "users")` 自动暴露的 REST 端点。提取 `path` 属性，未指定时从实体类名推导。

## @ConfigurationProperties 提取

`@ConfigurationProperties` 是 Spring Boot 类型安全配置绑定的核心机制：

### 类级别绑定（标准模式）
```java
@ConfigurationProperties(prefix = "app.mail")
@Validated
public class MailProperties {
    @NotBlank
    private String host;       // → app.mail.host
    private int port = 25;     // → app.mail.port
}
```

提取信息：
- `prefix` 值作为配置键前缀
- 类字段名 → 完整配置 key（`prefix.fieldName`）
- 字段默认值（如有赋值）
- `@Validated` + Bean Validation 注解 → 校验规则
- 字段 JavaDoc 注释作为配置项说明

### Relaxed Binding（完整 4 种形式）
Spring Boot 的属性绑定支持以下 4 种形式的属性名自动映射，不区分大小写：
| 形式 | 示例 | 适用格式 |
|------|------|----------|
| camelCase | `app.mail.hostName` | Java 字段名风格（含 `.properties`） |
| kebab-case | `app.mail.host-name` | `application.yml` 推荐风格 |
| underscore_notation | `app.mail.host_name` | `application.yml` 备选风格 |
| UPPER_CASE | `APP_MAIL_HOST_NAME` | 环境变量风格 |

扫描时需理解这 4 种形式均可绑定到同一 `hostName` 字段。

### @Bean + @ConfigurationProperties 方法绑定（绑定第三方类）
```java
@Bean
@ConfigurationProperties(prefix = "app.datasource")
public DataSourceProperties dataSourceProperties() {
    return new DataSourceProperties();
}
```
扫描 `@Bean` 方法上标注的 `@ConfigurationProperties`，提取 prefix 并关联到方法返回类型。

### @ConstructorBinding 构造器绑定
```java
@ConfigurationProperties(prefix = "app.server")
@ConstructorBinding
public class ServerProperties {
    private final String host;
    private final int port;

    public ServerProperties(String host, int port) {
        this.host = host;
        this.port = port;
    }
}
```
检测 `@ConstructorBinding` 注解（类级别或构造器级别），识别不可变配置类。

### Java Record 类型绑定（Spring Boot 3.x 推荐）
```java
@ConfigurationProperties(prefix = "app.server")
public record ServerProperties(String host, int port, Duration timeout) {}
```
Java record 类型上的 `@ConfigurationProperties` 天然支持不可变配置和构造器绑定，Spring Boot 3.x 推荐此模式。扫描 record 声明上的注解。

### 嵌套配置与 @NestedConfigurationProperty
- 嵌套 POJO 自动展平（`app.mail.host`）
- `@NestedConfigurationProperty` 标记的字段递归提取
- **递归终止条件**：遇到以下类型停止递归 —— 基本类型（int/long/boolean 等）、包装类（Integer/Long/Boolean 等）、`String`、`BigDecimal`/`BigInteger`、`Duration`、`URI`/`URL`、`Locale`、`Class<?>`、枚举类型。`java.util.*` 和 `java.time.*` 容器类型仅提取泛型参数，不深入映射元素内部。

### 示例输出
```json
{
  "configurationProperties": [
    {
      "class": "com.example.config.MailProperties",
      "prefix": "app.mail",
      "bindingMode": "class-level",
      "validated": true,
      "properties": [
        { "key": "app.mail.host", "type": "String", "defaultValue": null, "javadoc": "SMTP 服务器地址" },
        { "key": "app.mail.port", "type": "int", "defaultValue": "25", "javadoc": null }
      ]
    }
  ]
}
```

## Spring Boot 3.x 迁移特征检测

检测项目是否正在/已完成从 Spring Boot 2.x 到 3.x 的迁移：

### 版本检测
- 从 `pom.xml`/`build.gradle` 检测 Spring Boot 主版本（2.x vs 3.x）

### javax → jakarta 命名空间迁移
- 扫描 `pom.xml`/`build.gradle` 中的 `jakarta.*` 依赖（如 `jakarta.servlet:jakarta.servlet-api`）
- 扫描 `import javax.*` 语句 → 表明尚未完成迁移
- 同时检查 pom.xml `<dependencies>` 中 groupId 以 `javax.` 开头的遗留依赖（如 `javax.servlet:javax.servlet-api`），检测有无混用
- **部分迁移检测**：pom.xml 中同时存在 `javax.*` 和 `jakarta.*` 依赖 → 🟡 Warning：部分迁移状态

### auto-configuration 注册方式迁移
- 检测 `META-INF/spring.factories` 文件存在性（Spring Boot 2.x 方式）
- 检测 `META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports` 文件存在性（Spring Boot 3.x 方式）
- 两者同时存在 → 迁移中；仅存在 `spring.factories` → 尚未迁移

### WebSecurityConfigurerAdapter 废弃检测
- 扫描 `extends WebSecurityConfigurerAdapter` → 🔴 此基类在 Spring Security 6.0+ 已移除
- 检测是否已迁移到 `SecurityFilterChain` Bean 配置方式

### 路径匹配策略回退检测
- 检测 `application.yml` / `application.properties` 中是否配置了 `spring.mvc.pathmatch.matching-strategy=ant_path_matcher`
- 此配置为 Spring Boot 3.x 从 PathPatternParser 回退到 AntPathMatcher 的显式设置 → 记录存在性

### Security 注解迁移
- 检测 `@EnableGlobalMethodSecurity` 注解 → Spring Boot 2.x 遗留方式
- 检测 `@EnableMethodSecurity` 注解 → Spring Boot 3.x 推荐方式
- 二者同时存在 → 迁移中；仅存在旧注解 → 尚未迁移

### Spring Security FilterChain 配置
```java
@Bean
public SecurityFilterChain filterChain(HttpSecurity http) throws Exception {
    return http
        .authorizeHttpRequests(auth -> auth
            .requestMatchers("/api/public/**").permitAll()
            .requestMatchers("/api/admin/**").hasRole("ADMIN")
            .anyRequest().authenticated()
        )
        .oauth2Login(Customizer.withDefaults())
        .build();
}
```
- 检测 `SecurityFilterChain` Bean
- 提取 `requestMatchers` 路径模式及权限
- 识别认证方式：`formLogin()`, `oauth2Login()`, `oauth2ResourceServer()`, `httpBasic()`

## 项目结构

### 标准 Spring Boot 项目结构
```
src/main/java/<base-package>/
├── Application.java            # 启动类
├── common/                     # 公共类
├── config/                     # 配置类
├── controller/                 # 控制器
├── dto/                        # 数据传输对象
├── entity/                     # 实体类（或 domain/model）
├── exception/                   # 异常处理
├── mapper/                     # 数据访问（或 dao/repository）
├── service/                    # 业务逻辑
│   └── impl/                   # 实现类
└── vo/                         # 视图对象

src/main/resources/
├── application.yml
├── application-{profile}.yml
└── db/ 或 sql/

src/test/java/
└── ...
```

### 包结构统计
- 统计每个顶层包目录下的文件数
- 统计总计 .java 文件数
- 统计测试文件数（src/test/ 下）

## 模块计数（多模块 Maven 项目）

如果 pom.xml 包含 `<modules>`，统计模块数量。区分根 POM（`<packaging>pom</packaging>` + 含 `<modules>`）与普通子模块。

根 POM 的 `<dependencyManagement>` 通过 `<parent>` 链传递给各子模块，子模块可声明不含 `<version>` 的依赖。各子模块须独立检查 `src/main/java/` 确认是否为 Spring Boot 模块。

## Gradle 项目支持

- `build.gradle` / `build.gradle.kts` → Gradle 项目
- `settings.gradle` / `settings.gradle.kts` → 多模块项目
- `libs.versions.toml` → Gradle Version Catalog（提取 `[versions]`、`[libraries]`、`[plugins]`、`[bundles]`）
- `implementation(platform(...))` → BOM 导入
- `src/main/kotlin/` → Kotlin 项目（Spring Boot 的 Kotlin 变体，也支持 Kotlin + Maven 组合）

### Gradle 多项目配置蔓延
```kotlin
// settings.gradle.kts
include("module-a", "module-b")
includeBuild("../shared-lib")

// build.gradle.kts
subprojects { apply(plugin = "org.springframework.boot") }
allprojects { repositories { mavenCentral() } }
```
检测 `buildSrc/` 自定义插件、`subprojects`/`allprojects` 配置块。

## 非注解端点提取

### RouterFunction（Spring WebFlux / MVC）
扫描策略：
1. 寻找返回类型为 `RouterFunction<ServerResponse>` 的 `@Bean` 方法（支持 Java 和 Kotlin 文件）
2. 在方法体内匹配 `.GET(`、`.POST(`、`.PUT(`、`.DELETE(`、`.PATCH(` 调用，提取路径字符串和 handler 引用
3. 针对 `.nest(RequestPredicates.path("/prefix"), routes)` 进行递归解析 —— 将 `/prefix` 作为前缀拼接到内层路由的路径前
4. 提取 `accept(MediaType.xxx)` 等谓词作为附加条件

**简单示例**：
```java
@Bean
public RouterFunction<ServerResponse> userRoutes() {
    return route()
        .GET("/api/users/{id}", request -> ...)
        .POST("/api/users", request -> ...)
        .build();
}
```

**复杂示例（嵌套 + 过滤谓词）**：
```java
@Bean
public RouterFunction<ServerResponse> apiRoutes(UserHandler handler) {
    return nest(pathPrefix("/api"),
        nest(accept(MediaType.APPLICATION_JSON),
            route()
                .GET("/users/{id}", handler::getUser)
                .GET("/users", handler::listUsers)
                .POST("/users", handler::createUser)
        .andRoute(GET("/health"), request -> ok().build())
    );
}
// 提取结果：
// GET /api/users/{id}
// GET /api/users
// POST /api/users
// GET /health        ← 不在 nest 内
```

### Spring Cloud Gateway Java DSL 路由
```java
@Bean
public RouteLocator routes(RouteLocatorBuilder builder) {
    return builder.routes()
        .route("users", r -> r.path("/api/users/**").uri("lb://user-service"))
        .build();
}
```

### Spring Cloud Gateway YAML 配置路由（生产环境最常见）
```yaml
spring:
  cloud:
    gateway:
      routes:
        - id: user-route
          uri: lb://user-service
          predicates:
            - Path=/api/users/**
          filters:
            - StripPrefix=1
        - id: order-route
          uri: http://localhost:8082
          predicates:
            - Path=/api/orders/**
            - Host=order.example.com
          filters:
            - name: CircuitBreaker
              args:
                name: orderCB
```

提取策略：**不做白名单过滤，提取所有 predicates/filters 条目**：
- 每个 predicate/filter 条目提取 name 作为类型标识，args 作为键值对参数
- 简写形式（如 `Path=/api/users/**`）按约定解析：等号前为 name，等号后为 args 中的主参数
- `id`、`uri`（识别 `lb://`/`http://`/`ws://` 协议）始终提取

## BOM 导入检测

```xml
<dependencyManagement>
  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-dependencies</artifactId>
      <version>3.2.0</version>
      <type>pom</type>
      <scope>import</scope>
    </dependency>
  </dependencies>
</dependencyManagement>
```

BOM 导入是 Spring Boot 非 parent POM 继承的替代方案，已作为检测条件。

## gRPC / GraphQL 检测

- `io.grpc:grpc-*` → gRPC 服务（检查 `.proto` 文件或 `@GrpcService` 注解）
- `com.graphql-java-kickstart:graphql-spring-boot-starter` → GraphQL（检查 `@QueryMapping`/`@MutationMapping`）
- Spring Cloud 依赖（gateway/openfeign/loadbalancer 等）→ 微服务架构

## 未覆盖场景（已知限制）

- Quarkus / Micronaut / Helidon 等非 Spring Boot 框架：未被显式检测
- Spring Cloud Config / Consul / Vault / Nacos 等外部配置源：仅基于本地 yml 做审计
- 多级 parent POM 继承链路的跨模块版本解析：仅解析直接 parent，不递归追溯祖父 parent
- `@Value` 注解的动态表达式值：仅提取存在性，不解析运行时值
- AOT / GraalVM Native Image 配置：未覆盖
- Spring Modulith 模块化检测：未覆盖
- Spring Batch Job/Step 定义：未检测
- Reactive OpenAPI 变体（`@RouterOperations`）及 Kotlin Coroutines（`CoWebFilter`）：未覆盖

## Wrapper 检测

检测以下文件是否存在，用于更新 README 中的启动命令：
- `mvnw` / `mvnw.cmd` → Maven Wrapper
- `gradlew` / `gradlew.bat` → Gradle Wrapper
