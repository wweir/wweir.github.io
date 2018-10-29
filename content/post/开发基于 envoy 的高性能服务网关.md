---
title: "开发基于 Envoy 的高性能服务网关"
date: 2018-10-26T17:39:49+08:00
lastmod: 2018-10-26T17:39:49+08:00
draft: true
tags: 
- net
- grpc
categories: 
- dev
---

# Envoy 简介

说起 Envoy 可能听过的人不是很多，但如果说 service mesh，应该就有不少人听过了。目前 service mesh 一个使用较多、相对成熟的方案是结合 [kubernetes](https://kubernetes.io/)，使用 [Istio](https://istio.io/) 来实现服务网格，而 Istio 就是基于 envoy 的一个定制版本开发的。

Envoy 可以代理 tcp 和 udp 的流量，其中，对 http、grpc 等常用协议有很好的支持。Envoy 的架构对自定义插件提供了非常完善的支持，其自身的大部分功能也是以插件的方式对外提供的。工作时，Envoy 根据配置监听端口，再按照配置依次使用各相关插件处理流经的流量，整个思想与 UNIX 的 pipline 的思想保持一致，方便用户理解与使用，同时了提供强大自定义处理能力和很高的性能。

因为主要功能是通过插件实现，Envoy 便可以名正言顺得对很多第三方的服务提供对接支持，Envoy 自带的插件库已经提供了大多数常见功能的插件，能够直接满足我们的大多数需求。其中一些功能插件非常实用，比如各种监控服务。这个支持在普通的对外服务网关来说，作用可能不是很大。但对 service mesh 架构网关，或者普通内部服务网关来说，这个支持便是不可或缺的。如果 envoy 自带的插件库不能满足我们的需求，还可以自己去写一些插件来实现我们需要的功能。

#Envoy 项目特点

Envoy 使用 C++ 进行开发，完全使用 grpc 做配置管理，使用 bazel 做项目编译管理。不对外提供普通的二进制预编译版本，只提供了基于 docker 的预编译版本。如果进行二次开发，难免要进行编译等操作，需要注意，其部分依赖库需要开启代理才能下载，整个过程会比较折腾人。

## Envoy 目录结构

```bash
envoy
├── [ 480]  api
│   ├── [ 160]  bazel
│   ├── [ 448]  diagrams
│   ├── [  96]  docs
│   ├── [ 256]  envoy # API 的 protobuf 定义文件在这里
│   ├── [  96]  examples
│   ├── [ 128]  test
│   └── [ 256]  tools
├── [ 704]  bazel
│   └── [ 608]  external
├── [ 928]  ci
│   ├── [ 416]  build_container
│   └── [  96]  prebuilt
├── [ 576]  configs
│   ├── [ 128]  freebind
│   └── [ 192]  original-dst-cluster
├── [ 288]  docs
│   └── [ 480]  root
├── [ 320]  examples # 一些插件的使用示例
│   ├── [ 320]  fault-injection
│   ├── [ 352]  front-proxy
│   ├── [ 416]  grpc-bridge
│   ├── [ 320]  jaeger-native-tracing
│   ├── [ 256]  jaeger-tracing
│   ├── [ 224]  lua
│   └── [ 256]  zipkin-tracing
├── [  96]  include
│   └── [1.0K]  envoy
├── [ 128]  restarter
├── [ 224]  source # 主要源码在这里
│   ├── [1.0K]  common
│   ├── [ 224]  docs
│   ├── [ 320]  exe # main 入口
│   ├── [ 448]  extensions # 各插件源码
│   └── [1.2K]  server
├── [ 160]  support
│   └── [ 128]  hooks
├── [ 672]  test
│   ├── [ 960]  common
│   ├── [ 192]  config
│   ├── [ 224]  config_test
│   ├── [ 128]  coverage
│   ├── [ 256]  exe
│   ├── [ 416]  extensions
│   ├── [ 288]  fuzz
│   ├── [2.2K]  integration
│   ├── [ 928]  mocks
│   ├── [ 160]  proto
│   ├── [ 896]  server
│   ├── [ 800]  test_common
│   └── [ 160]  tools
├── [ 992]  tools
│   ├── [ 160]  deprecate_version
│   ├── [ 128]  envoy_collect
│   ├── [ 160]  protodoc
│   └── [  96]  testdata
└── [ 128]  windows
    ├── [  96]  setup
    └── [  96]  tools
```



# 网关需求分析

# Protobuf 定义配置文件的特点

