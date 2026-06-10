# README 模板：Monorepo

适用于：多包仓库、workspace 项目、微服务集合。

---

# Monorepo 名称

[![CI](https://img.shields.io/badge/build-passing-brightgreen)]()
[![License](https://img.shields.io/badge/license-MIT-blue)]()

一句话描述：本仓库包含 ___ 相关的一组项目/包。

## 📦 包列表

| 包名 | 路径 | 说明 |
|------|------|------|

## 🚀 快速开始

<!-- 包管理器由 readme-alive 根据项目构建文件自动检测（npm/yarn/pnpm/bun 等），替换为对应的命令 -->
```bash
# 克隆
git clone <repo-url>

# 安装所有依赖
<package-manager> install

# 构建所有包
<package-manager> build
```

## 🛠️ 共享技术栈

*此处列出各子包共享的技术栈及版本*

## 📁 目录结构

```
monorepo/
├── packages/
│   ├── package-a/    # 说明
│   └── package-b/    # 说明
├── docs/
└── package.json
```

## 🧪 测试

```bash
pnpm test
```

## ⚙️ 共享配置

本仓库使用以下共享配置：
- TypeScript：`tsconfig.base.json`
- ESLint：`eslint.config.js`

## 🤝 贡献

见 [CONTRIBUTING.md](./CONTRIBUTING.md)

## 📄 许可证

[License](./LICENSE)