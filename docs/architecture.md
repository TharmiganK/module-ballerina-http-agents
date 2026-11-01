# Architecture

How a request travels through the module, for tracing bugs from the public Ballerina API down to Netty. References name the file and method; line numbers drift, so grep for the method.

Paths below abbreviate `native/src/main/java/io/ballerina/stdlib/http/` as `native:`.

## Layers

| Layer | Location | Responsibility |
|---|---|---|
| Ballerina API | `ballerina/*.bal` | Public types, `http:Client`/`http:Listener`/`http:Caller`, client wrappers (resiliency, caching, cookies, auth), response/payload data binding on the client side. Calls Java through `@java:Method` externs (`'class: "io.ballerina.stdlib.http..."`). |
| Interop (`api`) | `native:api/` | Converts between Ballerina values and transport messages: service registration, dispatching, resource signature/parameter binding, invoking resources, writing responses, client actions. |
| URI templates | `native:uri/` | Path template parsing and matching used by dispatching. |
| Transport | `native:transport/` | Netty-based HTTP/1.1 and HTTP/2 server and client (formerly a separate transport library). `contract` = interfaces/config, `contractimpl` = implementation, `message` = `HttpCarbonMessage`. |
| Compiler plugin | `compiler-plugin/src/main/java/io/ballerina/stdlib/http/compiler/` | Compile-time validation and code generation; it does not run at request time. |

To find the Java implementation of a Ballerina extern, grep for the `'class:` string near the extern in the `.bal` file; the Java method name matches `name:` or the Ballerina function name.

## Inbound: request to a service resource

1. **Listener start.** `http:Listener` (`ballerina/http_service_endpoint.bal`) → `native:api/service/endpoint/{InitEndpoint,Register,Start}.java`. `Register` builds an `HttpService` and adds it to `HTTPServicesRegistry`.
2. **Netty receive.** `native:transport/contractimpl/listener/HttpServerChannelInitializer.java` builds the pipeline; `SourceHandler.channelRead` drives the state machine in `listener/states/` (HTTP/2: `listener/http2/`, `listener/states/http2/`). `ReceivingHeaders` creates the `HttpCarbonMessage` and calls `ServerConnectorFuture.notifyHttpListener`.
3. **Interop entry.** `native:api/BallerinaHTTPConnectorListener.onMessage` runs listener/service-level request interceptors first (`executeInterceptorServices`), then the main resource (`executeMainResourceOnMessage`).
4. **Dispatch.** `native:api/HttpDispatcher.findService` (base path match) → `HttpDispatcher.findResource` → `native:api/ResourceDispatcher.findResource`, which matches the path via `native:uri/URITemplate.java` and `native:uri/DispatcherUtil.java`, then the HTTP method. OPTIONS and OpenAPI/introspection resources are handled here too. No match → 404/405 error.
5. **Parameter binding.** `HttpDispatcher.getSignatureParameters` builds the argument list using `native:api/service/signature/ParamHandler.java` and the per-kind classes there (`PathParam`, `QueryParam`, `HeaderParam`, `PayloadParam`, ...). Payload binding goes through `signature/builder/*PayloadBuilder.java` and `signature/converter/`. Binding failures become 400 errors.
6. **Resource invocation.** `BallerinaHTTPConnectorListener.extractPropertiesAndStartResourceExecution` invokes the Ballerina resource; the result comes back to `native:api/HttpCallableUnitCallback.handleResult`.
7. **Response.** Either the resource calls `caller->respond()` (`ballerina/http_connection.bal`), or `HttpCallableUnitCallback` calls back into Ballerina `Caller.returnResponse`/`returnErrorResponse` (`http_connection.bal`) to convert a returned value, `StatusCodeResponse` or `error` into an `http:Response` (`createStatusCodeResponse` in `http_connection.bal`, `getErrorResponse` in `http_status_error_utils.bal`). Both end in `nativeRespond` → `native:api/nativeimpl/connection/Respond.java` → response interceptors (`Respond.invokeResponseInterceptor`) → `ResponseWriter` → transport `HttpOutboundRespListener` / `Http2OutboundRespListener`.

Interceptors: Ballerina types in `ballerina/http_interceptors.bal`; Java side `native:api/{InterceptorService,InterceptorResource,HTTPInterceptorServicesRegistry,HttpRequestInterceptorUnitCallback,HttpResponseInterceptorUnitCallback}.java`.

Listener auth: `ballerina/auth_listener_*.bal` and `auth_desugar.bal` (auth checks applied to resources with auth configuration).

## Outbound: `http:Client` call

1. **Construction.** `http:Client.init` (`ballerina/http_client_endpoint.bal`) → `initialize` wraps the base client according to config: circuit breaker, redirect, retry, cookie and caching clients (`resiliency_*.bal`, `redirect_http_client.bal`, `cookie_http_client.bal`, `caching_http_caching_client.bal`) around `HttpClient` (`ballerina/http_client.bal`, `createClient`). Load balance and failover clients are separate client types.
2. **Call.** A resource or remote method on `http:Client` (`http_client_endpoint.bal`) adds auth headers (`auth_client_*.bal`) and calls through the wrapper chain to `HttpClient`, whose externs land in `native:api/client/actions/HttpClientAction.java` (`get`, `post`, `execute`, `forward`, ...; `Submit`, `Forward`, `Execute` for the corresponding actions).
3. **Send.** `AbstractHTTPAction.executeNonBlockingAction` → `send` → `native:transport/contractimpl/DefaultHttpClientConnector.send`, which acquires a connection from `sender/channel/pool/` (HTTP/2: `sender/http2/`), and writes via the state machine in `sender/states/`.
4. **Receive.** `native:transport/contractimpl/sender/TargetHandler.channelRead` assembles the response and completes the response future, which resumes the Ballerina strand with an `http:Response` or `ClientError`.
5. **Data binding.** Back in Ballerina, `processResponse` / `processResponseNew` (`http_client_endpoint.bal`) and `performDataBinding` (`http_client_payload_builder.bal`) convert the response to the requested target type, including status code response binding (`http_status_code_client*.bal`). Binding failures produce `ClientError` subtypes.

## Errors

- Ballerina error types: `ballerina/http_errors.bal`; mapping of errors returned from resources to status codes and error payloads: `getErrorResponse`/`getStatusCode` in `ballerina/http_status_error_utils.bal` (`getErrorResponseForInterceptor` for interceptors).
- Java creates them via `native:api/HttpUtil.createHttpError(..., HttpErrorType)`; `native:api/HttpErrorType.java` maps Java error kinds to Ballerina error type names.

## Compiler plugin

`HttpCompilerPlugin.java` registers analyzers and modifiers:

- Validation (diagnostic codes in `HttpDiagnostic.java`): `HttpServiceAnalyzer` registers syntax-node tasks such as `HttpServiceValidator`; resource, interceptor and service-contract checks live in `HttpResourceValidator`, `HttpInterceptorServiceValidator`, `HttpInterceptorResourceValidator` and `HttpServiceContractResourceValidator`.
- `codemodifier/` (`HttpServiceModifier`): rewrites source before compilation, e.g. adding `@http:Payload` to inferred payload parameters (`payload/PayloadAnnotationModifierTask.java`) and service contract handling (`contract/`).
- `codeaction/`, `completion/`: IDE features. `staticcodeanalyzer/` (`HttpStaticCodeAnalyzer`): rules documented in spec section 11. `oas/`, `OpenAPISpecGenerator.java`: OpenAPI generation for introspection.

A bug that shows up as a wrong or missing compile error belongs here, not in `native/`.
