# x86-64 OpenWrt 基线

从官方 OpenWrt `x86/64 / generic` 出发的全新基线：第一版不加 `files/`、不加额外软件包，只用官方 ImageBuilder 和官方默认包。定制逐项加在这个基础上。

## 版本

`profiles/build.env` 固定 OpenWrt 版本和官方 ImageBuilder 容器的 digest。`scripts/update-pins.sh` 把它们更新到同一系列（现为 25.12.x）的最新补丁版本；出现新的发布系列时只输出 `notice:`，不自动切换，需要人工评估。

## 构建

在 x86_64 主机上安装并启动 Docker，然后执行：

```sh
./scripts/build.sh
```

输出保存在 `artifacts/<版本>/<UTC时间>/`，包含镜像、包清单、构建输入和日志。`./scripts/build.sh --manifest-only <文件>` 只解析软件包，不生成镜像。容器以 `--ulimit nofile=1024:524288` 启动，避免 fakeroot 在无限制 nofile 的主机上挂起。Mac 上的 amd64 仿真会让 `ucode`、`uci` 等偶发段错误，构建应在 x86_64 主机或 CI 上进行。
