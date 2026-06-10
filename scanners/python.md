# Python 扫描规则

## 检测条件

**主要**：
- 存在 `pyproject.toml`
- 存在 `setup.py` 或 `setup.cfg`
- 存在 `requirements.txt`（不再要求根目录有 `.py` 文件）
- 存在 `Pipfile` 或 `Pipfile.lock`
- 存在 `poetry.lock`
- 存在 `pdm.lock`
- 存在 `uv.lock`

**子类型判断**：
- 含 `fastapi` 依赖 → FastAPI 后端
- 含 `django` 依赖 → Django 应用
- 含 `flask` 依赖 → Flask 应用
- 含 `litestar` 依赖 → Litestar 应用
- 含 `sanic` 依赖 → Sanic 应用
- 含 `tornado` 依赖 → Tornado 应用
- 含 `click` 或 `typer` 依赖且无 Web 框架 → CLI 工具
- 代码中存在 `@click.command()` / `@click.group()` 装饰器 → CLI 工具
- 代码中存在 `@app.command()` 或 `typer.run()` → Typer CLI（详见 CLI 入口点提取章节的完整模式列表）
- `pyproject.toml` 中 `[project.scripts]` 定义了命令行入口 → CLI 工具
- `[tool.poetry]` → Poetry 管理
- `[tool.pdm]` → PDM 管理

## 技术栈提取

### pyproject.toml（PEP 621 / Poetry / PDM）

```toml
[project]
dependencies = ["fastapi>=0.100.0", "uvicorn[standard]"]

[project.optional-dependencies]
dev = ["pytest", "black"]
```

提取：
- `[project.dependencies]` → 运行时依赖
- `[project.optional-dependencies]` → 可选依赖
- Poetry: `[tool.poetry.dependencies]`
- PDM: `[tool.pdm.dev-dependencies]`

### requirements.txt

逐行解析 `package==version` 或 `package>=version`。

指令行处理规则：
- `-r <file>` → 记录被引用文件名但不追踪解析，标注 `[Info: references <file>]`
- `-e <path>` → 提取包名但标记为可编辑安装 `[Editable]`
- `-c <file>` → 记录约束文件名但不应用，标注 `[Info: constrained by <file>]`
- 环境标记（如 `; python_version < '3.12'`）→ 保留标记字符串但不过滤

### setup.py / setup.cfg

提取 `install_requires` 参数。

> **已知限制**：`setup.py` 中动态计算（函数调用/条件分支）的 `install_requires` 静态提取可能不完整，标注 `[Partial: static extraction from setup.py]`。

重点关注的依赖类别：
- Web 框架：fastapi, django, flask, starlette, litestar, sanic, tornado, quart, aiohttp
- 数据库：sqlalchemy, tortoise-orm, django-orm, psycopg2, asyncpg
- 缓存：redis, aioredis, cachetools
- 消息队列：kafka-python, aiokafka, celery, dramatiq
- 数据验证：pydantic, marshmallow
- CLI：click, typer, rich, textual, argparse（stdlib）
- 测试：pytest, unittest

## API 端点提取

### FastAPI

```python
from fastapi import FastAPI

app = FastAPI()

@app.get("/users/{id}")
async def get_user(id: int):
    ...

@app.post("/users")
async def create_user(user: UserCreate):
    ...
```

扫描模式：
- `@app.get("/path")` / `@app.post("/path")` / `@app.put("/path")` / `@app.delete("/path")` / `@app.patch("/path")`
- `@router.get("/path")` / `@router.post("/path")` 等
- `APIRouter(prefix="/prefix")` → 前缀 + 路由路径

提取信息：
- HTTP 方法 + 完整路径
- 路径参数（`{id}`）
- 函数名和 docstring 首行

#### WebSocket 端点

```python
@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    ...
```

扫描 `@app.websocket("/path")` / `@router.websocket("/path")`。

#### include_router 前缀汇总

```python
app.include_router(user_router, prefix="/users")
app.include_router(order_router, prefix="/orders", tags=["orders"])
```

扫描 `app.include_router(...)` → 汇总各子路由前缀，形成完整路由表。

**前缀合并规则**：当 `include_router()` 和 `APIRouter()` 同时声明 prefix 时：
```
最终路径 = include_router(prefix) + APIRouter(prefix) + 路由路径
```
示例：
```python
# users/router.py
router = APIRouter(prefix="/v1")

# main.py
app.include_router(users_router, prefix="/users")
# 路由 @router.get("/profile") → 最终路径: /users/v1/profile
```

#### Depends 依赖注入链

```python
from fastapi import Depends

def get_current_user(token: str = Depends(oauth2_scheme)): ...

@app.get("/me")
async def read_me(current_user: User = Depends(get_current_user)): ...
```

扫描函数参数中 `= Depends(...)` → 构建依赖链拓扑。

**输出格式**：多层嵌套的 Depends 展平为链式结构：
```json
{
  "depends_chain": [
    {
      "endpoint": "/me",
      "chain": ["read_me", "get_current_user", "oauth2_scheme"]
    }
  ]
}
```
规则：递归追踪 `Depends(...)` 参数 → 按调用顺序展平为数组，每个元素为被依赖函数名。

#### Middleware 和异常处理

```python
@app.middleware("http")
async def add_process_time(request: Request, call_next): ...

@app.exception_handler(ValueError)
async def value_error_handler(request, exc): ...
```

#### Lifespan / on_event 钩子

```python
# 方式一：lifespan context manager（推荐）
@asynccontextmanager
async def lifespan(app: FastAPI):
    # startup
    yield
    # shutdown

app = FastAPI(lifespan=lifespan)

# 方式二：on_event 装饰器（已弃用但仍常见）
@app.on_event("startup")
async def startup_event(): ...

@app.on_event("shutdown")
async def shutdown_event(): ...
```

扫描 `@app.on_event('startup')` / `@app.on_event('shutdown')` 和 `lifespan=` 参数中的 context manager。

### Django

```python
# urls.py
urlpatterns = [
    path("users/", views.user_list, name="user-list"),
    path("users/<int:id>/", views.user_detail, name="user-detail"),
]
```

扫描 `urlpatterns` 列表中的 `path()` / `re_path()` 调用。

路径转换器完整枚举：

| 转换器 | 匹配类型 | 示例 |
|--------|---------|------|
| `str` | 非空字符串（默认） | `<str:name>` |
| `int` | 零或正整数 | `<int:id>` |
| `slug` | ASCII 字母/数字/连字符/下划线 | `<slug:title>` |
| `uuid` | UUID 字符串 | `<uuid:pk>` |
| `path` | 非空字符串含 `/` | `<path:filepath>` |

#### re_path() 正则组提取

`re_path()` 使用命名正则组：
```python
re_path(r'^users/(?P<user_id>[0-9a-f-]+)/$', views.user_detail)
```
提取规则：`(?P<name>pattern)` → 参数名 = `name`，类型标注为 `[regex: pattern]`。

#### 类视图 as_view() 模式

```python
urlpatterns = [
    path("users/", views.UserListView.as_view(), name="user-list"),
    path("users/<int:pk>/", views.UserDetailView.as_view(), name="user-detail"),
]
```

扫描 `as_view()` 调用 → 从类方法名推断 HTTP 方法（`get`→GET, `post`→POST 等）。

#### include() namespace 参数

```python
path('api/', include('users.urls', namespace='users')),
```

提取 `include(...)` 的 `namespace` 参数作为路由命名空间。

#### register_converter() 自定义转换器

```python
from django.urls import register_converter

class FourDigitYearConverter:
    regex = '[0-9]{4}'
    def to_python(self, value): ...
    def to_url(self, value): ...

register_converter(FourDigitYearConverter, 'yyyy')
```

**行为定义**：遇到 `register_converter()` 自定义转换器时，输出 `[Warning]` 标记该路径模式使用了自定义转换器，路径模式保留原始 `<converter:param>` 文本不做展开，提醒用户人工补充。

### Flask

```python
@app.route("/users/<int:id>", methods=["GET"])
def get_user(id):
    ...
```

扫描 `@app.route("/path", methods=[...])` 或 `@bp.route("/path")`。

**Flask URL 转换器枚举**：

| 转换器 | 匹配类型 | 示例 |
|--------|---------|------|
| `string` | 非空字符串（默认） | `<string:name>` |
| `int` | 整数 | `<int:id>` |
| `float` | 正浮点数 | `<float:price>` |
| `path` | 字符串含 `/` | `<path:filepath>` |
| `uuid` | UUID 字符串 | `<uuid:id>` |
| `any` | 给定选项之一 | `<any(admin,user):role>` |

#### MethodView 编程式路由

```python
from flask.views import MethodView

class UserAPI(MethodView):
    def get(self, user_id): ...
    def post(self): ...

app.add_url_rule("/users/<int:user_id>", view_func=UserAPI.as_view("user_api"))
```

扫描 `MethodView` 子类 + `app.add_url_rule()` / `bp.add_url_rule()`。

**通用 add_url_rule() 检测**（不仅限 MethodView 上下文）：
```python
app.add_url_rule('/path', view_func=func, methods=['GET', 'POST'])
bp.add_url_rule('/path', view_func=other_func, methods=['POST'])
```
任何 `app.add_url_rule(...)` 或 `bp.add_url_rule(...)` 调用均需检测，提取路径、`view_func` 函数名、`methods` 列表。

#### Blueprint url_prefix 拼接

```python
bp = Blueprint("users", __name__, url_prefix="/users")

@bp.route("/<int:id>")
def user_detail(id): ...
```

提取 `Blueprint(..., url_prefix="/prefix")` → 与路由装饰器路径拼接。

#### 请求钩子

```python
@app.before_request
def load_current_user(): ...

@app.after_request
def add_header(response): ...
```

扫描 `@app.before_request` / `@app.after_request` / `@app.teardown_request`。

## CLI 入口点提取

### argparse（stdlib）

```python
import argparse

parser = argparse.ArgumentParser(description="CLI tool")
parser.add_argument("input", help="input file path")
parser.add_argument("--output", "-o", default="out.txt")
parser.add_argument("--verbose", action="store_true")
subparsers = parser.add_subparsers(dest="command")
subparsers.add_parser("init")
args = parser.parse_args()
```

扫描 `argparse.ArgumentParser()`、`add_argument()`、`add_subparsers()`。

### click

```python
import click

@click.command()
@click.option("--name", prompt="Your name", help="The person to greet.")
@click.argument("output")
def hello(name, output): ...
```

不仅依赖名检测，还需代码级确认 `@click.command()` / `@click.group()` 装饰器。

### typer

```python
import typer

app = typer.Typer()

@app.command()
def init(name: str, force: bool = typer.Option(False, help="Force init")): ...

if __name__ == "__main__":
    typer.run(main)
```

扫描 `@app.command()` / `typer.Typer()` / `typer.run()`。此为 Typer CLI 检测的权威来源（子类型判断处通过引用指向此处）。

### pyproject.toml [project.scripts]

```toml
[project.scripts]
mycli = "myapp.cli:main"
serve = "myapp.server:run"
```

提取 `[project.scripts]` 和 `[tool.poetry.scripts]` 中的 CLI 入口点。

### setup.cfg / PDM 入口点

```ini
# setup.cfg
[options.entry_points]
console_scripts =
    mycli = myapp.cli:main
```

```toml
# pyproject.toml
[tool.pdm.scripts]
dev = "uvicorn app.main:app --reload"
test = "pytest -v"
```

提取 `[options.entry_points]` 中的 `console_scripts` 和 `[tool.pdm.scripts]` 中定义的命令。

## 配置项提取

### pydantic-settings BaseSettings

```python
from pydantic_settings import BaseSettings, SettingsConfigDict
from pydantic import Field

class AppSettings(BaseSettings):
    """应用配置"""
    model_config = SettingsConfigDict(
        env_prefix="APP_",
        env_file=".env",
    )

    host: str = "0.0.0.0"
    port: int = 8000
    database_url: str = Field(alias="DATABASE_URL")
    redis_url: str | None = None
```

扫描模式：
- `class ...(BaseSettings):` → 配置类识别
- 类字段 → 环境变量 key（默认大写，如 `host: str` → `HOST`）
- `model_config = SettingsConfigDict(env_prefix="APP_")` → 前缀（如上例 `host` → `APP_HOST`）
- `Field(alias="...")` → 自定义别名。**精确行为**：`Field(alias='X')` 完全跳过前缀推导，env var 名精确为 alias 值 `X`（前缀不附加）
- `env_file=".env"` → .env 文件加载关系

**env_file 扩展**：
- `env_file` 支持列表形式：`env_file=[".env", ".env.prod"]`（按顺序加载，先找到的值优先）
- `secrets_dir` 检测：`secrets_dir="/run/secrets"` → Docker secrets 目录

**env_nested_delimiter**：
```python
model_config = SettingsConfigDict(env_nested_delimiter="__")
```
嵌套模型字段的 env var 拼接：`database.host` → `APP_DATABASE__HOST`（默认分隔符 `__`）。

**Pydantic v1 class Config 兼容**：
```python
# Pydantic v1 模式（仍广泛存在）
from pydantic import BaseSettings

class AppSettings(BaseSettings):
    class Config:
        env_prefix = "APP_"
        env_file = ".env"

    host: str = "0.0.0.0"
```
检测 `class Config:` 内部类的 `env_prefix` / `env_file` 等字段，与 `SettingsConfigDict` 等同处理。

提取输出格式：

```json
{
  "settings_class": "AppSettings",
  "env_prefix": "APP_",
  "env_files": [".env"],
  "fields": [
    {"name": "host", "type": "str", "env_key": "APP_HOST", "default": "0.0.0.0"},
    {"name": "port", "type": "int", "env_key": "APP_PORT", "default": 8000},
    {"name": "database_url", "type": "str", "env_key": "DATABASE_URL", "alias": true, "default": null}
  ]
}
```

### pyproject.toml

提取 `[tool.*]` 下的配置块（每个工具可能有自己的配置）。

### .env.example

```bash
DATABASE_URL=postgresql://localhost/db
REDIS_URL=redis://localhost:6379
SECRET_KEY=your-secret-key
```

提取 `KEY=VALUE` 对，值脱敏处理（仅保留类型信息）。

### 环境变量读取

扫描代码中的 `os.environ["KEY"]` / `os.getenv("KEY")` / `os.getenv("KEY", "default")`。

## Django REST Framework ViewSet（关键补充）

```python
from rest_framework.viewsets import ModelViewSet
from rest_framework.routers import DefaultRouter

class UserViewSet(ModelViewSet):
    queryset = User.objects.all()
    serializer_class = UserSerializer

router = DefaultRouter()
router.register('users', UserViewSet)  # 自动生成 5 个 REST 端点
```

- `router.register('prefix', ViewSet)` → 自动端点：GET/POST/PUT/PATCH/DELETE `prefix/`
- `@action(detail=True, methods=['post'])` → 自定义 action 端点

**`@action` 装饰器完整参数**：
```python
@action(detail=False, methods=['get'], url_path='active', url_name='user-active')
def active_users(self, request): ...
```
- `detail=False` → 生成集合级端点（`/users/active/`），不包含 `{pk}`
- `detail=True`（默认）→ 生成详情级端点（`/users/{pk}/activate/`）
- `url_path` → 覆盖自动生成的 URL 路径段
- `url_name` → 覆盖自动生成的 URL 名称
- `methods` → 允许任意 HTTP 方法列表（不仅限 `['post']`）

**DefaultRouter vs SimpleRouter**：
- `SimpleRouter`：仅生成基本 CRUD 路由
- `DefaultRouter`：继承 SimpleRouter，额外生成 API 根视图（`GET /` 返回所有注册路由列表）+ 尾部斜杠自动重定向

### ReadOnlyModelViewSet

```python
class UserReadOnlyViewSet(ReadOnlyModelViewSet):
    queryset = User.objects.all()
    serializer_class = UserSerializer

router.register('users', UserReadOnlyViewSet)  # 仅 GET 集合和 GET 详情
```

### GenericViewSet + Mixin 组合

```python
from rest_framework.mixins import ListModelMixin, RetrieveModelMixin
from rest_framework.viewsets import GenericViewSet

class UserListViewSet(ListModelMixin, RetrieveModelMixin, GenericViewSet):
    queryset = User.objects.all()
    serializer_class = UserSerializer
```

扫描继承链中的 Mixin 类确定生成端点：`ListModelMixin`→GET集合, `CreateModelMixin`→POST, `RetrieveModelMixin`→GET详情, `UpdateModelMixin`→PUT（全量更新）+ PATCH（部分更新）, `DestroyModelMixin`→DELETE。

### drf-nested-routers 嵌套路由

```python
from rest_framework_nested.routers import NestedDefaultRouter

router = DefaultRouter()
router.register('users', UserViewSet)
users_router = NestedDefaultRouter(router, 'users', lookup='user')
users_router.register('orders', OrderViewSet, basename='user-orders')
```

生成嵌套 URL：`/users/{user_pk}/orders/`。

## Django include() 嵌套路由

```python
urlpatterns = [
    path('api/', include([
        path('users/', include('users.urls')),
        path('orders/', include('orders.urls')),
    ])),
]
```

**字符串引用 `include('app.urls')` 文件定位规则**：
- `include('users.urls')` → 将 `.` 替换为 `/` 后追加 `/urls.py` → `users/urls.py`
- `include('django.contrib.admin.urls')` → `django/contrib/admin/urls.py`（不追踪第三方/内置包内部文件）

**递归深度上限**：`include()` 嵌套解析最多 5 层深度。超过 5 层标注 `[Warning: include recursion depth exceeded]`。

**内联 include 列表**：
```python
include([
    path('a/', view_a),
    path('b/', view_b),
])
```
直接解析列表内的 `path()` / `re_path()` 调用，prefix 为外层 `path()` 的第一个参数。

**namespace 参数提取**：
```python
path('api/', include('users.urls', namespace='users'))
```
提取 `namespace` 参数作为路由命名空间，与路由名称组合为 `namespace:name`。

## gRPC / GraphQL 检测

- `grpcio` / `grpcio-tools` → gRPC 服务
- `graphene` / `strawberry-graphql` / `ariadne` → GraphQL

## 项目结构

### Python 项目布局

Python 项目通常有两种源码布局：

**src-layout**（推荐）：
```
project/
├── src/
│   └── package/
│       ├── __init__.py
│       ├── module.py
│       └── subpackage/
│           └── __init__.py
├── tests/
├── pyproject.toml
└── README.md
```

**flat-layout**：
```
project/
├── package/
│   ├── __init__.py
│   └── module.py
├── tests/
├── pyproject.toml
└── README.md
```

**源代码文件搜索起点**：优先 `src/` 目录，未命中则回退到项目根目录。排除目录：`node_modules/`、`.git/`、`__pycache__/`、`.venv/`、`venv/`、`.tox/`、`*.egg-info/`。

**模块统计规则**：含 `__init__.py` 的顶层目录计为一个模块。

### Django 项目结构

```
project/
├── manage.py                     # Django 管理入口
├── project/
│   ├── __init__.py
│   ├── settings/
│   │   ├── __init__.py
│   │   ├── base.py               # 公共配置
│   │   ├── dev.py                # 开发环境
│   │   └── prod.py               # 生产环境
│   ├── urls.py                   # 根 URL 配置
│   ├── wsgi.py                   # WSGI 入口
│   └── asgi.py                   # ASGI 入口（Django 3.0+）
├── apps/
│   ├── users/
│   │   ├── models.py
│   │   ├── views.py
│   │   ├── urls.py
│   │   ├── serializers.py        # DRF
│   │   └── tests.py
│   └── orders/
│       └── ...
├── static/
├── media/
├── templates/
└── requirements.txt
```

### FastAPI 项目结构

**单文件模式**（小型应用）：
```
project/
├── main.py                       # FastAPI 应用 + 路由
├── requirements.txt
└── .env
```

**模块化模式**（中大型应用）：
```
project/
├── app/
│   ├── __init__.py
│   ├── main.py                   # FastAPI 应用实例
│   ├── core/
│   │   ├── __init__.py
│   │   └── config.py             # pydantic-settings
│   ├── routers/
│   │   ├── __init__.py
│   │   ├── users.py
│   │   └── orders.py
│   ├── models/
│   │   ├── __init__.py
│   │   ├── user.py
│   │   └── order.py
│   ├── schemas/
│   │   ├── __init__.py
│   │   ├── user.py
│   │   └── order.py
│   ├── services/
│   │   ├── __init__.py
│   │   ├── user_service.py
│   │   └── order_service.py
│   └── dependencies.py           # Depends 函数
├── tests/
├── alembic/                      # 数据库迁移
│   └── versions/
├── alembic.ini
├── pyproject.toml
└── .env
```

### Flask 项目结构

```
project/
├── app/
│   ├── __init__.py               # create_app() 工厂函数
│   ├── models/
│   ├── views/ 或 routes/
│   ├── templates/
│   ├── static/
│   │   ├── css/
│   │   ├── js/
│   │   └── images/
│   └── forms.py                  # WTForms
├── instance/                     # 实例配置（Flask 约定）
│   └── config.py
├── migrations/                   # Flask-Migrate
├── tests/
├── requirements.txt
└── config.py
```

### CLI 工具结构

```
project/
├── src/
│   └── cli/
│       ├── __init__.py
│       ├── main.py               # 主入口
│       ├── commands/
│       │   ├── __init__.py
│       │   ├── init.py
│       │   └── build.py
│       └── utils/
│           ├── __init__.py
│           └── helpers.py
├── tests/
└── pyproject.toml
```

### 测试目录约定

- 优先搜索 `tests/` 目录（现代约定）
- 回退搜索 `test/` 目录
- Django 项目额外搜索各 app 内的 `tests.py` 或 `tests/` 包
- 统计测试文件数和测试框架（pytest / unittest）

## 未覆盖场景（已知限制）

- `requirements.txt` 复杂语法（`-r` / `-c` / `-e` / 环境标记）：指令行记录文件名和标记但不追踪解析
- Dynaconf / 外部配置源：不被提取
- 纯脚本项目（无任何构建文件）：需依赖文件扩展名推断
- Litestar / Sanic / Tornado / aiohttp / Quart 框架：仅做依赖名检测，不做端点路由提取
- uv 工作空间（workspace / `[tool.uv.sources]`）：检测到 `[tool.uv.workspace]` 或 `[tool.uv.sources]` 时，尝试读取 members 列表并记录各成员包路径，标注 `[Partial: uv workspace]`
- 自定义 `register_converter`（Django）：输出 `[Warning]` 标记，路径模式保留原始 `<converter:param>` 文本不做展开，提醒用户人工补充
- `setup.py` 动态 `install_requires`（函数调用/条件分支）：静态提取可能不完整，标注 `[Partial: static extraction from setup.py]`
- flit / maturin / scikit-build-core 等构建系统：仅做基本文件检测，不提取 build-system 配置

## 包管理器检测

| 文件 | 包管理器 |
|------|---------|
| `pyproject.toml` 含 `[tool.poetry]` | Poetry |
| `pyproject.toml` 含 `[tool.pdm]` | PDM |
| `pyproject.toml` 含 `[tool.hatch]` | Hatch |
| `setup.py` / `setup.cfg` | setuptools |
| `requirements.txt` | pip |
| `Pipfile` | Pipenv |
| `pyproject.toml` 含 `[tool.uv]` 或 `uv.lock` | uv |

用于更新 README 中的安装命令。