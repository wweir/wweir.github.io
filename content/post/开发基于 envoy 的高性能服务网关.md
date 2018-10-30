---
title: "开发基于 Envoy 的高性能服务网关"
date: 2018-10-26T17:39:49+08:00
lastmod: 2018-10-26T17:39:49+08:00
draft: false
tags: 
- net
- grpc
- protobuf
categories: 
- dev
---

# Envoy 简介

说起 Envoy，听过的人可能不是很多，但如果说 service mesh（服务网格），应该就有不少人听过了。目前 service mesh 一个使用较多、相对成熟的方案是配置 [kubernetes](https://kubernetes.io/)，使用 [Istio](https://istio.io/) 来实现，而 Istio 就是基于 envoy 的一个定制版本开发的。

Envoy 可以代理 tcp 和 udp 的流量，其中，对 http、grpc、Thrift 等常用协议有很好的支持。Envoy 的架构对插件提供了非常完善的支持，其自身的大部分功能便是以插件的方式对外提供的。工作时，Envoy 根据配置监听端口，再按照配置依次使用插件处理流经的流量，整体思想与 UNIX 的 pipline 保持一致，方便用户理解与使用，同时实现了强大自定义处理能力和很高的性能。

因为通过插件实现主要功能，Envoy 便可以名正言顺得对很多第三方的服务提供对接支持，Envoy 自带的插件库已经提供了大多数常见功能的插件，能够直接满足我们的大多数需求。如果 envoy 自带的插件库不能满足我们的需求，还可以自己去写一些插件来实现我们需要的功能。

其中一些功能插件非常实用，比如对 [zipkin](https://zipkin.io/)、[jaeger](https://www.jaegertracing.io/) 这两个主流 tracing 服务的支持。这个支持在普通的对外服务网关来说，作用可能不是很大。但对 service mesh 架构网关，或者内部统一服务网关来说，这个支持是不可或缺的。

# Envoy 项目特点

Envoy 使用 C++ 进行开发，完全基于 protobuf 做配置管理，使用 bazel 做项目编译管理。不对外提供普通的二进制预编译版本，只提供了基于 docker 的预编译版本。

> 如果进行二次开发，难免要进行编译等操作，需要注意的是：其部分依赖库需要开启代理才能下载，整个过程会比较折腾人。

Envoy 的代码托管在 [github](https://github.com/envoyproxy/envoy)，它被放在 [Envoy Proxy](https://github.com/envoyproxy) 这个组织下面，这个组织下面提供了一些有用的工具。如果需要基于 Envoy 进行开发功能，一定记得看一下 Envoy Proxy 这个组织下面是不是已经有了一些项目可以借用。

Envoy 的[文档](https://www.envoyproxy.io/docs/envoy/latest/)比较有意思，其中很多内容绑定在 protobuf 定义上进行讲解，所以它的组织结构不太符合常见文档的结构。初次实用，可能觉得难以接受，但熟悉之后，会发觉这样的文档组织形式，还是非常实用的，版本、层次结构都非常清晰。

## Envoy 源码目录结构

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

Envoy 再好，如果不贴合实际需求的话，还是不会选择它，让我们来看看 Envoy 满足了我们哪些需求，我们为什么会选择它。

## 性能

我们需要的是一个对公网提供服务的网关，所以流量会比较大，并且长短连接都有。要求网关：

1. 单实例能够提供较高性能
2. 自身无状态，能够方便扩缩容

Envoy 自身由 C++ 写成，同时使用了优良的架构，单实例性能远超 nginx 之类兼职的网关。

Envoy 自身可由配置文件或 grpc 进行配置，如果不手动更改配置文件，仅通过 grpc 进行配置，完全可以做到自身无状态，扩缩容非常方便。

## 功能

我们的这个网关，是提供给 SaaS 服务使用的，所以会有一些特殊的需求：

1. 路由，这算是服务网关的标配功能了
2. 动态配置，运行时增删改路由配置，算是入门级功能
3. OAuth 认证服务，这算是 SaaS 场景下的特殊需求
4. 限流、熔断、计数等监控、调度类功能
5. 协议转换

 Envoy 自带的插件已经非常丰富，这里列出的大部分需求，已经可以直接使用：

1. `http_connection_manager`  插件里面有 route 配置支持。为此，还专门提供了`Dynamic Route Discovery Service(RDS)` 这个配置点，可以非常方便的动态配置路由。
2. 前面已经提到了 `RDS` 这个动态配置点。除此之外，还有 `CDS`（cluster）、`EDS`(endpoint)、`LDS`(Listener) 等数个动态配置点，可以完整地进行动态配置。有意思的是，动态配置服务自身的配置，也放在了这些配置里面，所以，动态配置服务自身也可以动态配置。
3. OAuth 这个需求的定制化要求比较高，具体的代码、流程需要在外部进行定义，Envoy 的 `ext_authz` 插件可以在外部执行这个认证过程。特别需要注意的是，`ext_authz` 插件仅会拷贝 http 请求的头部到外部认证服务，所以虽然认证服务运行在外部，但是性能消耗是可以接受的。
4. Envoy 提供了 `Rate limit` 插件，可以针对多种协议进行限速操作。如果有其它需求，可以尝试借用 `ext_authz` 进行实现。
5. 协议转换这个功能，在我们这里不算是强需求，如果后续需要的话，需要自己写插件进行实现。

# Protobuf 定义配置

## 亮点

对比 Envoy 和其它常见的服务，它的整体设计思想可以说很有意思：

- 服务主体只实现了很少的功能，因为功能少，可以很容易得保证服务自身的稳定性。
- 服务的配置虽然完全通过 protobuf 来定义，但同时提供了 protobuf、yaml、json 三种配置文件格式的支持。运行时，使用 [**转换器**](https://github.com/envoyproxy/envoy/blob/0aa97c582de4588143d42c8f3b5ab6898f4afb80/source/common/protobuf/utility.cc#L81) 将 yaml、json 等格式的配置转换成 protobuf 的配置。
  - protobuf 官方已经提供了很多格式转换方面的支持，需要自己进行的工作并不多。
- 由于配置完全定义成 protobuf 格式，我们就可以很方便得实现动态配置的功能，只需要加上 [`grpc`](https://grpc.io/) 支持就可以。
- 对于较为复杂的配置，可以拆分为数个单独的 `Dynamic Discovery Service`。
- 整个文档体系依托 protobuf 定义文件，进行展开，甚至是自动生成。

以上这些点，不仅在 envoy 这套生态下有用，对于我们自己的的服务，也有很大的借鉴意义。

## 痛点

不过 Envoy 里面也并不是全部是好的东西，以下两点，可以说令我深恶痛绝：

- 文档组织混乱，整个文档依托 protobuf 进行生成，本身就意味着文档的展开顺序并不符合普通用户的学习、查询曲线。而 Envoy  为了用户能了解它文档的组织形式，又在文档正文外部有加了一层讲解与归类，遗憾的是这些讲解做的并不好，反而导致整个文档显得有些混乱，令新接触的人头痛不已。
- Envoy 为了所有的 protobuf 定义都更加规范，引用了数个硕大的 protobuf 预定义集，导致整个项目在编译期显得异常臃肿。最尴尬的是这几个预定义集内的命名有很多重名与类似的情况，在进行定制开发时，很容易被绕晕。

# 总结

总体来说 Envoy 自身是一个优秀的网关，无论是自身质量还是对定制的友好度。同时，其设计上有很多有意思的思想，可以借鉴到我们的日常开发中。