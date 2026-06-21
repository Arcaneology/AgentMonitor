# ADR-0003：采用非沙盒直接分发

## 状态

已接受

## 背景

应用需要读取同 UID 进程信息、执行系统工具、检查用户项目目录并发送终止信号。App Sandbox 会限制这些核心能力。

## 决策

首版关闭 App Sandbox，保持 Hardened Runtime，通过 Developer ID 签名和 Apple 公证后直接分发。不安装 privileged helper，也不请求管理员权限。

## 影响

优点：能够完成核心监控和停止操作，同时把权限限制在当前用户。  
缺点：不适合 Mac App Store 分发；发布流程需要 Developer ID 和公证。

## 备选方案

- App Sandbox 加 XPC helper：权限和安装复杂度明显增加，且首版没有操作系统进程的需求。
- Mac App Store：分发方便，但沙盒约束与核心功能冲突。

