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

## 检查与测试

- `scripts/verify-image.sh`：在 ImageBuilder 容器里解开 rootfs 镜像，检查版本和目标与 `build.env` 一致、有 init、procd 和 dropbear，并且 `lib/apk/db/installed` 里的包与本次解析出的 manifest 完全一致。
- `tests/vm/`：用 QEMU（UEFI、NVMe、两个 e1000e 网口）启动 combined EFI 镜像。官方镜像没有 root 密码，所以只用串口日志、ping 和 TCP 连接检查：无 kernel panic、UEFI 启动、procd 初始化完成、LAN 地址 `192.168.1.1` 可 ping、SSH 端口可连、没有网页服务。

## 自动构建与发布

GitHub Actions 工作流 `Build firmware`（`.github/workflows/build.yml`）每天北京时间 03:37 定时运行，也可手动运行（可选“强制构建”）；推送代码不会触发构建。

1. 先执行 `scripts/update-pins.sh`，把 OpenWrt 更新到同一系列的最新补丁版本。出现更新的发布系列时不自动切换，开一个 issue 提醒。
2. 解析软件包（`build.sh --manifest-only`），用 `scripts/build-state.sh` 计算配方和包清单的状态，与最近一次 Release 附带的 `build-state.txt` 比较；没有变化就结束。
3. 有变化时构建，依次运行镜像检查和虚拟机测试。全部通过后由 `scripts/release.sh` 发布：先把更新后的 `profiles/` 提交并推送，再创建 Release，附带镜像、包清单、构建信息、检查日志和 `SHA256SUMS`。任何一步失败都不提交、不发布。
4. 不会自动刷机。

目前这些脚本和测试都还没有在真实构建上运行过。
