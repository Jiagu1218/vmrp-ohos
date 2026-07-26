
#ifndef _MSC_VER
#include <pthread.h>
#endif
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "./include/compat_msvc.h"
#include "./include/network.h"
#include "./include/posix_sockets.h"
#include "include/types.h"

#ifndef WIN_PLAT
#include <fcntl.h>
#endif

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#include <emscripten/websocket.h>
#include <emscripten/threading.h>

EMSCRIPTEN_WEBSOCKET_T bridgeSocket = 0;

EMSCRIPTEN_WEBSOCKET_T emscripten_init_websocket_to_posix_socket_bridge(const char* bridgeUrl);
#endif

enum {
    MR_SOCK_STREAM,
    MR_SOCK_DGRAM
};

enum {
    MR_IPPROTO_TCP,
    MR_IPPROTO_UDP
};

enum {
    MR_SOCKET_BLOCK,
    MR_SOCKET_NONBLOCK
};

typedef struct {
    SOCKET_T s;
    uint32_t sendCounter;
    int32_t realState;  // 真正的连接状态
    int32_t state;      // cmwap模式下是一个伪状态，cmnet模式下与realState的值始终相同
    int32_t cmwapMode;  // Socket 创建时的网络模式；不能被后续 mr_initNetwork(CMNET) 污染
    int32_t cmwapProxyAck;  // cmwap模式：真实连接建立后需要返回伪造的代理200响应
} mSocket;

static int isCMWAP = FALSE;  // 当前 mr_initNetwork 模式，只用于之后新建的 socket
static struct rb_root sockets = RB_ROOT;

#define SKYENGINE_DNS_MAP_MAX 32
#define SKYENGINE_DNS_ROUTE_MAX 256
#define VMRP_DNS_NAME_MAX 255
#define VMRP_DNS_ROUTE_TOKEN_PREFIX 0xF0000000u

typedef struct {
    char original[VMRP_DNS_NAME_MAX + 1];
    char fake[VMRP_DNS_NAME_MAX + 1];
    int hasFakePort;
    uint16_t fakePort;
} DnsMapEntry;

static DnsMapEntry dnsMap[SKYENGINE_DNS_MAP_MAX];
static int dnsMapCount = 0;
static uint32_t dnsMapGeneration = 0;

typedef struct {
    uint32_t token;
    uint32_t resolvedIp;
    uint32_t generation;
    uint16_t port;
} DnsRouteRecord;

static DnsRouteRecord dnsRoutes[SKYENGINE_DNS_ROUTE_MAX];
static int dnsRouteCount = 0;
static uint32_t dnsRouteSequence = 0;

typedef struct {
    char name[VMRP_DNS_NAME_MAX + 1];
    int mapped;
    int hasPort;
    uint16_t port;
    uint32_t generation;
} DnsLookupTarget;

#ifdef _MSC_VER
static SRWLOCK dnsMapLock = SRWLOCK_INIT;
static void lockDnsMap(void) { AcquireSRWLockExclusive(&dnsMapLock); }
static void unlockDnsMap(void) { ReleaseSRWLockExclusive(&dnsMapLock); }
#else
static pthread_mutex_t dnsMapLock = PTHREAD_MUTEX_INITIALIZER;
static void lockDnsMap(void) { pthread_mutex_lock(&dnsMapLock); }
static void unlockDnsMap(void) { pthread_mutex_unlock(&dnsMapLock); }
#endif

#define VMRP_NET_LOG_ENABLED() (getenv("SKYENGINE_NETWORK_LOG") != NULL || getenv("SKYENGINE_LOG") != NULL)
#define VMRP_NET_LOG(...)                       \
    do {                                       \
        if (VMRP_NET_LOG_ENABLED()) {          \
            fprintf(stderr, "[skyengine-net] ");    \
            fprintf(stderr, __VA_ARGS__);      \
            fflush(stderr);                    \
        }                                      \
    } while (0)

#ifdef _MSC_VER
typedef HANDLE VmrpThread;
typedef DWORD(WINAPI *VmrpThreadStart)(void *);
#define VMRP_THREAD_RET DWORD WINAPI
#define VMRP_THREAD_DONE 0
#else
typedef pthread_t VmrpThread;
typedef void *(*VmrpThreadStart)(void *);
#define VMRP_THREAD_RET void *
#define VMRP_THREAD_DONE NULL
#endif

static int startDetachedThread(VmrpThread *thread, VmrpThreadStart start, void *arg) {
#ifdef _MSC_VER
    DWORD threadId = 0;
    HANDLE handle = CreateThread(NULL, 0, start, arg, 0, &threadId);
    if (!handle) {
        return MR_FAILED;
    }
    /*
     * Network callbacks already own their heap payload.  The emulator never
     * joins these short-lived workers, so close the Windows handle immediately
     * while leaving the thread running, matching the existing POSIX fire-and-
     * forget behavior without leaking kernel handles.
     */
    if (thread) *thread = handle;
    CloseHandle(handle);
    if (thread) *thread = NULL;
    return MR_SUCCESS;
#else
    return pthread_create(thread, NULL, start, arg) == 0 ? MR_SUCCESS : MR_FAILED;
#endif
}

static char* trimSpaces(char* s) {
    char* end;
    while (*s && isspace((unsigned char)*s)) s++;
    end = s + strlen(s);
    while (end > s && isspace((unsigned char)*(end - 1))) end--;
    *end = '\0';
    return s;
}

static int copyNormalizedDomain(char* dst, size_t dstSize, const char* src) {
    size_t len;
    if (!dst || dstSize == 0 || !src) return MR_FAILED;
    while (*src && isspace((unsigned char)*src)) src++;
    len = strlen(src);
    while (len > 0 && isspace((unsigned char)src[len - 1])) len--;
    while (len > 0 && src[len - 1] == '.') len--;
    if (len == 0 || len >= dstSize) return MR_FAILED;
    for (size_t i = 0; i < len; i++) {
        unsigned char ch = (unsigned char)src[i];
        if (isspace(ch)) return MR_FAILED;
        dst[i] = (char)tolower(ch);
    }
    dst[len] = '\0';
    return MR_SUCCESS;
}

static int parsePortNumber(const char* src, uint16_t* outPort) {
    int value = 0;
    if (!src || !*src || !outPort) return MR_FAILED;
    while (*src) {
        if (!isdigit((unsigned char)*src)) return MR_FAILED;
        value = value * 10 + (*src - '0');
        if (value > 65535) return MR_FAILED;
        src++;
    }
    if (value == 0) return MR_FAILED;
    *outPort = (uint16_t)value;
    return MR_SUCCESS;
}

static int copyNormalizedDnsTarget(char* dst, size_t dstSize, uint16_t* outPort,
                                   int* outHasPort, const char* src) {
    char endpoint[VMRP_DNS_NAME_MAX + 1];
    char* colon;
    if (!dst || !outPort || !outHasPort) return MR_FAILED;
    if (copyNormalizedDomain(endpoint, sizeof(endpoint), src) != MR_SUCCESS) return MR_FAILED;

    *outHasPort = FALSE;
    *outPort = 0;
    colon = strrchr(endpoint, ':');
    if (colon) {
        if (strchr(endpoint, ':') != colon) return MR_FAILED;
        *colon = '\0';
        if (parsePortNumber(colon + 1, outPort) != MR_SUCCESS) return MR_FAILED;
        *outHasPort = TRUE;
    }
    if (copyNormalizedDomain(dst, dstSize, endpoint) != MR_SUCCESS) return MR_FAILED;
    return MR_SUCCESS;
}

static int parseDnsMapEntry(char* entry) {
    char* sep;
    char* original;
    char* fake;
    char originalNorm[VMRP_DNS_NAME_MAX + 1];
    char fakeNorm[VMRP_DNS_NAME_MAX + 1];
    uint16_t fakePort = 0;
    int hasFakePort = FALSE;

    entry = trimSpaces(entry);
    if (!*entry) return MR_SUCCESS;

    sep = strstr(entry, "->");
    if (sep) {
        *sep = '\0';
        fake = sep + 2;
    } else {
        sep = strchr(entry, '=');
        if (!sep) return MR_FAILED;
        *sep = '\0';
        fake = sep + 1;
    }

    original = trimSpaces(entry);
    fake = trimSpaces(fake);
    if (copyNormalizedDomain(originalNorm, sizeof(originalNorm), original) != MR_SUCCESS ||
        copyNormalizedDnsTarget(fakeNorm, sizeof(fakeNorm), &fakePort, &hasFakePort, fake) != MR_SUCCESS) {
        return MR_FAILED;
    }
    if (dnsMapCount >= SKYENGINE_DNS_MAP_MAX) return MR_FAILED;

    DnsMapEntry* target = &dnsMap[dnsMapCount];
    memset(target, 0, sizeof(*target));
    strcpy(target->original, originalNorm);
    strcpy(target->fake, fakeNorm);
    target->hasFakePort = hasFakePort;
    target->fakePort = fakePort;
    if (hasFakePort) {
        VMRP_NET_LOG("dns_map[%d]: %s -> %s:%u\n", dnsMapCount, originalNorm, fakeNorm, (unsigned)fakePort);
    } else {
        VMRP_NET_LOG("dns_map[%d]: %s -> %s\n", dnsMapCount, originalNorm, fakeNorm);
    }
    dnsMapCount++;
    return MR_SUCCESS;
}

static void invalidateDnsRoutesLocked(void) {
    dnsRouteCount = 0;
    dnsMapGeneration++;
    if (dnsMapGeneration == 0) dnsMapGeneration = 1;
}

int32 my_configureDnsMap(const char* map) {
    char* buf;
    char* entry;
    char* next;

    lockDnsMap();
    dnsMapCount = 0;
    invalidateDnsRoutesLocked();
    VMRP_NET_LOG("configure_dns_map raw='%s'\n", map ? map : "(null)");
    if (!map || !*map) {
        VMRP_NET_LOG("configure_dns_map cleared\n");
        unlockDnsMap();
        return MR_SUCCESS;
    }

    buf = malloc(strlen(map) + 1);
    if (!buf) {
        unlockDnsMap();
        return MR_FAILED;
    }
    strcpy(buf, map);

    entry = buf;
    while (entry && *entry) {
        next = entry;
        while (*next && *next != ',' && *next != ';' && *next != '\n' && *next != '\r') {
            next++;
        }
        if (*next) {
            *next = '\0';
            next++;
        } else {
            next = NULL;
        }
        if (parseDnsMapEntry(entry) != MR_SUCCESS) {
            free(buf);
            dnsMapCount = 0;
            VMRP_NET_LOG("configure_dns_map failed at entry='%s'\n", entry);
            unlockDnsMap();
            return MR_FAILED;
        }
        entry = next;
    }

    free(buf);
    VMRP_NET_LOG("configure_dns_map count=%d\n", dnsMapCount);
    unlockDnsMap();
    return MR_SUCCESS;
}

static int getDnsLookupTarget(const char* name, DnsLookupTarget* target) {
    char normalized[VMRP_DNS_NAME_MAX + 1];
    int count;

    if (!target || copyNormalizedDomain(normalized, sizeof(normalized), name) != MR_SUCCESS) {
        VMRP_NET_LOG("dns_lookup invalid name='%s'\n", name ? name : "(null)");
        return MR_FAILED;
    }

    memset(target, 0, sizeof(*target));
    strcpy(target->name, normalized);
    lockDnsMap();
    for (int i = dnsMapCount - 1; i >= 0; i--) {
        if (strcmp(dnsMap[i].original, normalized) == 0) {
            strcpy(target->name, dnsMap[i].fake);
            target->mapped = TRUE;
            target->hasPort = dnsMap[i].hasFakePort;
            target->port = dnsMap[i].fakePort;
            target->generation = dnsMapGeneration;
            break;
        }
    }
    count = dnsMapCount;
    unlockDnsMap();

    if (!target->mapped) {
        VMRP_NET_LOG("dns_lookup miss: %s (entries=%d)\n", normalized, count);
    } else if (target->hasPort) {
        printf("dns map: %s -> %s:%u\n", name, target->name, (unsigned)target->port);
        VMRP_NET_LOG("dns_lookup hit: %s -> %s:%u generation=%u\n",
                     normalized, target->name, (unsigned)target->port,
                     (unsigned)target->generation);
    } else {
        printf("dns map: %s -> %s\n", name, target->name);
        VMRP_NET_LOG("dns_lookup hit: %s -> %s\n", normalized, target->name);
    }
    return MR_SUCCESS;
}

enum {
    DNS_ROUTE_ERROR = -1,
    DNS_ROUTE_NONE = 0,
    DNS_ROUTE_APPLIED = 1
};

static int dnsRouteTokenInUseLocked(uint32_t token) {
    for (int i = 0; i < dnsRouteCount; i++) {
        if (dnsRoutes[i].token == token) return TRUE;
    }
    return FALSE;
}

static int createDnsMappedRoute(const DnsLookupTarget* target, uint32_t resolvedIp,
                                uint32_t* outToken) {
    DnsRouteRecord* route;
    uint32_t token;

    if (!target || !target->hasPort || !outToken) return MR_FAILED;

    lockDnsMap();
    if (target->generation != dnsMapGeneration) {
        unlockDnsMap();
        return MR_FAILED;
    }

    /* Reusing an identical immutable endpoint bounds repeated lookups without
     * changing any token already returned to the guest. */
    for (int i = 0; i < dnsRouteCount; i++) {
        route = &dnsRoutes[i];
        if (route->generation == target->generation &&
            route->resolvedIp == resolvedIp && route->port == target->port) {
            *outToken = route->token;
            unlockDnsMap();
            return MR_SUCCESS;
        }
    }
    if (dnsRouteCount >= SKYENGINE_DNS_ROUTE_MAX) {
        VMRP_NET_LOG("dns_route capacity exhausted (%d)\n", SKYENGINE_DNS_ROUTE_MAX);
        unlockDnsMap();
        return MR_FAILED;
    }

    /* A distinct DNS answer gets an immutable route, so it cannot redirect a
     * token already returned to the guest.  Skip -1, the ABI failure value. */
    do {
        dnsRouteSequence = (dnsRouteSequence + 1) & 0x0FFFFFFFu;
        token = VMRP_DNS_ROUTE_TOKEN_PREFIX | dnsRouteSequence;
    } while (token == UINT32_MAX || dnsRouteTokenInUseLocked(token));

    route = &dnsRoutes[dnsRouteCount++];
    route->token = token;
    route->resolvedIp = resolvedIp;
    route->generation = target->generation;
    route->port = target->port;
    *outToken = token;
    unlockDnsMap();
    return MR_SUCCESS;
}

static int applyDnsMappedRoute(int32_t* ip, uint16_t* port) {
    uint32_t token;
    uint32_t resolvedIp = 0;
    uint16_t mappedPort = 0;
    int found = FALSE;

    if (!ip || !port) return DNS_ROUTE_ERROR;
    token = (uint32_t)*ip;

    lockDnsMap();
    for (int i = 0; i < dnsRouteCount; i++) {
        if (dnsRoutes[i].token == token && dnsRoutes[i].generation == dnsMapGeneration) {
            resolvedIp = dnsRoutes[i].resolvedIp;
            mappedPort = dnsRoutes[i].port;
            found = TRUE;
            break;
        }
    }
    unlockDnsMap();

    /* Only an exact active token is synthetic.  Unmatched values, including
     * ordinary 240/4 addresses and stale tokens, retain normal IPv4 behavior. */
    if (!found) return DNS_ROUTE_NONE;
    *ip = (int32_t)resolvedIp;
    *port = mappedPort;
    VMRP_NET_LOG("dns_route hit: token=0x%X -> ip=0x%X port=%u\n",
                 (unsigned)token, (unsigned)resolvedIp, (unsigned)mappedPort);
    return DNS_ROUTE_APPLIED;
}

/* 从 "host" 或 "host:port" 形式的字符串里提取 host 和 port。
 * h 指向起始位置，遇到 '\0'、'\r'、'\n'、' '、'/' 停止。 */
static int extractHostPort(const char* h, char* outHost, int outHostLen, uint16_t* outPort) {
    int i;
    for (i = 0; i < outHostLen - 1; i++) {
        if (*h == '\0' || *h == ':' || *h == '/' || *h == '\r' || *h == '\n' || *h == ' ') {
            break;
        }
        outHost[i] = *h;
        h++;
    }
    outHost[i] = '\0';
    if (i == 0) return -1;  // 没提取到任何内容

    if (*h == ':') {
        char port[6];
        h++;  // 跳过':'
        for (i = 0; i < (int)sizeof(port) - 1; i++) {
            if (*h == '\0' || *h == '/' || *h == '\r' || *h == '\n' || *h == ' ') {
                break;
            }
            port[i] = *h;
            h++;
        }
        port[i] = '\0';
        *outPort = (uint16_t)atoi(port);
    } else {
        *outPort = 80;
    }
    return 0;
}

/* 从 HTTP 请求数据中解析目标 host:port。
 * 支持三种格式：
 *   1) "CONNECT host:port HTTP/x.x"          — HTTPS 代理隧道
 *   2) "GET http://host:port/path HTTP/x.x"   — 绝对 URL
 *   3) "POST /path HTTP/x.x\r\nHost: host:port\r\n..."  — Host 头（netpay 走这个）
 * buf 是完整的 HTTP 请求数据（不只首行）。 */
static int parseHostPort(const char* buf, int bufLen, char* outHost, int outHostLen, uint16_t* outPort) {
    const char* h;

    // 格式 1: CONNECT host:port
    if (strncmp(buf, "CONNECT ", 8) == 0) {
        return extractHostPort(buf + 8, outHost, outHostLen, outPort);
    }

    // 格式 2: 绝对 URL (GET http://host/...)
    h = strstr(buf, "://");
    if (h != NULL && h < buf + bufLen) {
        return extractHostPort(h + 3, outHost, outHostLen, outPort);
    }

    // 格式 3: 从 Host 头提取（不区分大小写）
    // 在 buf 中逐行扫描，查找 "Host:" 头
    const char* p = buf;
    const char* end = buf + bufLen;
    while (p < end) {
        // 跳到下一行
        const char* lineEnd = p;
        while (lineEnd < end && *lineEnd != '\r' && *lineEnd != '\n') lineEnd++;

        int lineLen = (int)(lineEnd - p);
        if (lineLen >= 5 && strncasecmp(p, "Host:", 5) == 0) {
            const char* val = p + 5;
            while (val < lineEnd && *val == ' ') val++;  // 跳过空格
            return extractHostPort(val, outHost, outHostLen, outPort);
        }

        // 跳过 \r\n
        if (lineEnd < end && *lineEnd == '\r') lineEnd++;
        if (lineEnd < end && *lineEnd == '\n') lineEnd++;
        if (lineEnd == p) break;  // 防止死循环
        p = lineEnd;
    }

    return -1;
}

typedef struct {
    VmrpThread th;
    mSocket* s;
    uint32_t ip;
    uint16_t port;
} connectData_t;

#define VMRP_CONNECT_TIMEOUT_MS 2000

static int isConnectPendingError(int error) {
#ifdef WIN_PLAT
    return error == WSAEWOULDBLOCK || error == WSAEINPROGRESS || error == WSAEALREADY;
#else
    return error == EINPROGRESS || error == EWOULDBLOCK || error == EALREADY;
#endif
}

static int32 my_connectSync(SOCKET_T s, int32 ip, uint16 port) {
    struct sockaddr_in clientService;
    int32 result = MR_FAILED;
    int connectError = 0;
#ifdef WIN_PLAT
    u_long nonblocking = 1;
#else
    int originalFlags;
#endif

    clientService.sin_family = AF_INET;
    clientService.sin_port = htons(port);
    clientService.sin_addr.s_addr = htonl(ip);  //inet_addr("127.0.0.1");

    printf("my_connect(fd:%d, '%s', %d)\n", (int)s, inet_ntoa(clientService.sin_addr), port);
    VMRP_NET_LOG("connect fd=%d target=%s:%u ip=0x%X\n",
                 (int)s, inet_ntoa(clientService.sin_addr), (unsigned)port, (unsigned)ip);

#ifdef WIN_PLAT
    if (ioctlsocket(s, FIONBIO, &nonblocking) != 0) {
        connectError = GET_SOCKET_ERROR();
        goto done;
    }
#else
    originalFlags = fcntl(s, F_GETFL, 0);
    if (originalFlags == -1 || fcntl(s, F_SETFL, originalFlags | O_NONBLOCK) == -1) {
        connectError = GET_SOCKET_ERROR();
        goto done;
    }
#endif

    if (connect(s, (struct sockaddr*)&clientService, sizeof(clientService)) == 0) {
        result = MR_SUCCESS;
    } else {
        connectError = GET_SOCKET_ERROR();
        if (isConnectPendingError(connectError)) {
            fd_set writefds;
            struct timeval timeout = {
                .tv_sec = VMRP_CONNECT_TIMEOUT_MS / 1000,
                .tv_usec = (VMRP_CONNECT_TIMEOUT_MS % 1000) * 1000
            };
            FD_ZERO(&writefds);
            FD_SET(s, &writefds);
#ifdef WIN_PLAT
            int selected = select(0, NULL, &writefds, NULL, &timeout);
#else
            int selected = select(s + 1, NULL, &writefds, NULL, &timeout);
#endif
            if (selected > 0 && FD_ISSET(s, &writefds)) {
                int socketError = 0;
#ifdef WIN_PLAT
                int socketErrorLen = sizeof(socketError);
                int getErrorResult = getsockopt(s, SOL_SOCKET, SO_ERROR,
                                                (char*)&socketError, &socketErrorLen);
#else
                socklen_t socketErrorLen = sizeof(socketError);
                int getErrorResult = getsockopt(s, SOL_SOCKET, SO_ERROR,
                                                &socketError, &socketErrorLen);
#endif
                if (getErrorResult == 0 && socketError == 0) {
                    result = MR_SUCCESS;
                } else {
                    connectError = getErrorResult == 0 ? socketError : GET_SOCKET_ERROR();
                }
            } else if (selected == 0) {
#ifdef WIN_PLAT
                connectError = WSAETIMEDOUT;
#else
                connectError = ETIMEDOUT;
#endif
            } else {
                connectError = GET_SOCKET_ERROR();
            }
        }
    }

#ifdef WIN_PLAT
    nonblocking = 0;
    if (ioctlsocket(s, FIONBIO, &nonblocking) != 0 && result == MR_SUCCESS) {
        result = MR_FAILED;
        connectError = GET_SOCKET_ERROR();
    }
#else
    if (fcntl(s, F_SETFL, originalFlags) == -1 && result == MR_SUCCESS) {
        result = MR_FAILED;
        connectError = GET_SOCKET_ERROR();
    }
#endif

done:
    if (result == MR_SUCCESS) {
        printf("my_connect(0x%X) suc\n", ip);
        VMRP_NET_LOG("connect success ip=0x%X\n", (unsigned)ip);
    } else {
        printf("my_connect(0x%X) fail\n", ip);
        VMRP_NET_LOG("connect failed ip=0x%X socket_error=%d\n",
                     (unsigned)ip, connectError);
    }
    return result;
}

static VMRP_THREAD_RET my_connectAsync(void* arg) {
    connectData_t* data = (connectData_t*)arg;
    int32_t r = my_connectSync(data->s->s, data->ip, data->port);
    data->s->realState = r;
    if (!data->s->cmwapMode) {  // cmnet模式下保持相同的连接状态
        data->s->state = r;
    } else if (r == MR_SUCCESS) {
        data->s->cmwapProxyAck = 1;  // 触发伪造的代理200响应
    }
    free(data);
    return VMRP_THREAD_DONE;
}
/*
   MR_SUCCESS 成功
   MR_FAILED 失败
   MR_WAITING 使用异步方式进行连接，应用需要轮询该socket的状态以获知连接状况 

   IP地址,如果一个主机的IP地址为218.18.95.203，则值为218<<24 + 18<<16 + 95<<8 + 203= 0xda125fcb
*/
int32 my_connect(int32 s, int32 ip, uint16 port, int32 type) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* data = (mSocket*)obj->data;
    int routeResult = applyDnsMappedRoute(&ip, &port);
    if (routeResult == DNS_ROUTE_ERROR) {
        data->state = MR_FAILED;
        data->realState = MR_FAILED;
        return MR_FAILED;
    }
    if (ip == 0x0A0000AC && data->cmwapMode) {
        // 10.0.0.172 是 CMWAP 代理地址，桌面端不存在该代理
        // 伪装连接成功，实际连接在 my_send 第一次发送时根据 CONNECT 头建立
        data->state = MR_SUCCESS;
        data->realState = MR_WAITING;
        return MR_SUCCESS;
    }
    printf("my_connect() type: %s\n", type == MR_SOCKET_BLOCK ? "block" : "async");
    VMRP_NET_LOG("my_connect guest_socket=%d host_fd=%d ip=0x%X port=%u type=%s cmwap=%d\n",
                 s, (int)data->s, (unsigned)ip, (unsigned)port,
                 type == MR_SOCKET_BLOCK ? "block" : "async", data->cmwapMode);
    if (type == MR_SOCKET_NONBLOCK) {
        connectData_t* d = malloc(sizeof(connectData_t));
        d->s = data;
        d->ip = ip;
        d->port = port;
        if (startDetachedThread(&d->th, my_connectAsync, d) != MR_SUCCESS) {
            free(d);
            data->state = MR_FAILED;
            data->realState = MR_FAILED;
            return MR_FAILED;
        }
        return MR_WAITING;
    }
    return my_connectSync(data->s, ip, port);
}

/*
   MR_SUCCESS ： 连接成功
   MR_FAILED ： 连接失败
   MR_WAITING ： 连接中
   MR_IGNORE ： 不支持该功能
*/
int32 my_getSocketState(int32 s) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* p = ((mSocket*)obj->data);
    printf("my_getSocketState(%d): %d\n", s, p->state);
    return p->state;
}

static int32_t socketCounter = 0;
int32 my_hasOpenSockets(void) {
    return rb_first(&sockets) != NULL;
}

int32 my_openSocketCount(void) {
    int32 count = 0;
    for (struct rb_node* node = rb_first(&sockets); node; node = rb_next(node))
        count++;
    return count;
}

/*
 >=0 返回的Socket句柄 
   MR_FAILED 失败 
*/
int32 my_socket(int32 type, int32 protocol) {
    type = (type == MR_SOCK_STREAM) ? SOCK_STREAM : SOCK_DGRAM;
    protocol = (protocol == MR_IPPROTO_TCP) ? IPPROTO_TCP : IPPROTO_UDP;
    SOCKET_T sock = socket(AF_INET, type, protocol);
    if (sock == -1) {
        printf("my_socket() fail\n");
        return MR_FAILED;
    }
    socketCounter++;

    mSocket* data = malloc(sizeof(mSocket));
    data->s = sock;
    data->realState = MR_WAITING;
    data->state = MR_WAITING;
    data->sendCounter = 0;
    data->cmwapMode = isCMWAP;
    data->cmwapProxyAck = 0;

    uIntMap* obj = malloc(sizeof(uIntMap));
    obj->key = socketCounter;
    obj->data = (void*)data;
    uIntMap_insert(&sockets, obj);
    // 打印宿主 fd: 排查 fd 复用/串线问题时必须能把 guest socket id 对应到宿主 fd
    printf("my_socket(): s=%d fd=%d\n", socketCounter, (int)sock);
    return socketCounter;
}

int32 my_closeSocket(int32 s) {
    uIntMap* obj = uIntMap_delete(&sockets, (uint32_t)s);
    if (obj == NULL) {
        return MR_FAILED;
    }
    mSocket* data = (mSocket*)obj->data;
    SOCKET_T sock = data->s;
    free(data);
    free(obj);
    printf("my_closeSocket(s:%d): fd=%d\n", s, (int)sock);
    shutdown(sock, SHUTDOWN_BIDIRECTIONAL);
    if (CLOSE_SOCKET(sock) != 0) {
        return MR_FAILED;
    }
    return MR_SUCCESS;
}

int32 my_closeNetwork(void) {
    struct rb_node* p;
    while ((p = rb_first(&sockets)) != NULL) {
        uIntMap* obj = rb_entry(p, uIntMap, node);
        my_closeSocket((int32)obj->key);
    }
#ifdef WIN_PLAT
    WSACleanup();
#endif
    lockDnsMap();
    invalidateDnsRoutesLocked();
    unlockDnsMap();
    return MR_SUCCESS;
}

typedef struct {
    MR_INIT_NETWORK_CB cb;
    void* userData;
    uc_engine* uc;
    VmrpThread th;
} initNetworkAsyncData_t;

static int32 my_initNetworkSync(void) {
#ifdef WIN_PLAT
    WSADATA wsaData;
    int iResult = WSAStartup(MAKEWORD(2, 2), &wsaData);
    if (iResult != 0) {
        printf("WSAStartup failed: %d\n", iResult);
        return MR_FAILED;
    }
    if (LOBYTE(wsaData.wVersion) != 2 || HIBYTE(wsaData.wVersion) != 2) {
        printf("Could not find a usable version of Winsock.dll\n");
        my_closeNetwork();
        return MR_FAILED;
    }
#elif defined(__EMSCRIPTEN__)
    bridgeSocket = emscripten_init_websocket_to_posix_socket_bridge("ws://127.0.0.1:8888/socket");
    // Synchronously wait until connection has been established.
    uint16_t readyState = 0;
    do {
        emscripten_websocket_get_ready_state(bridgeSocket, &readyState);
        emscripten_thread_sleep(100);
        printf("readyState:%d\n", readyState);
    } while (readyState == 0);
#endif
    return MR_SUCCESS;
}

static VMRP_THREAD_RET my_initNetworkAsync(void* arg) {
    initNetworkAsyncData_t* data = (initNetworkAsyncData_t*)arg;
    int32 r = my_initNetworkSync();
    printf("my_initNetworkAsync(): %d\n", r);
    /* cb/userData 装的是 guest 32 位地址(经指针类型转运),显式经 uintptr_t
     * 截断,语义与原先的直接窄化转换一致 */
    bridge_dsm_network_cb(data->uc, (uint32_t)(uintptr_t)data->cb, r,
                          (uint32_t)(uintptr_t)data->userData);
    free(data);
    return VMRP_THREAD_DONE;
}

/*  
   MR_SUCCESS 同步模式，初始化成功，不再调用cb
   MR_FAILED （立即感知的）失败，不再调用cb
   MR_WAITING 使用回调函数通知引擎初始化结果 
*/
int32 my_initNetwork(uc_engine* uc, MR_INIT_NETWORK_CB cb, const char* mode, void* userData) {
    printf("my_initNetwork(0x%p, '%s')\n", cb, mode);
    VMRP_NET_LOG("init_network mode='%s' cb=%p\n", mode ? mode : "(null)", (void*)cb);
    /* Mythroad apps can reinitialize the network with CMNET after a CMWAP
     * download.  The active mode must therefore be replaced, not only ever
     * promoted to CMWAP, otherwise later async connects stay visibly WAITING. */
    isCMWAP = (strncasecmp("cmwap", mode, 5) == 0) ? TRUE : FALSE;
    if (cb != NULL) {
        initNetworkAsyncData_t* data = malloc(sizeof(initNetworkAsyncData_t));
        data->cb = cb;
        data->userData = userData;
        data->uc = uc;
        if (startDetachedThread(&data->th, my_initNetworkAsync, data) != MR_SUCCESS) {
            free(data);
            return MR_FAILED;
        }
        return MR_WAITING;
    }
    return my_initNetworkSync();
}

typedef struct {
    char* name;
    MR_GET_HOST_CB cb;
    void* userData;
    uc_engine* uc;
    VmrpThread th;
} getHostByNameAsyncData_t;

static int32 my_getHostByNameSync(const char* name) {
    int32 ret = MR_FAILED;
    DnsLookupTarget target;
    if (getDnsLookupTarget(name, &target) != MR_SUCCESS) return MR_FAILED;

#if 1
    struct addrinfo *result, *res;
    printf("getaddrinfo of %s\n", target.name);
    VMRP_NET_LOG("get_host name='%s' lookup='%s'\n", name ? name : "(null)", target.name);
    int gai = getaddrinfo(target.name, NULL, NULL, &result);
    if (gai != 0) {
        printf("getaddrinfo failed!\n");
        VMRP_NET_LOG("getaddrinfo failed name='%s' lookup='%s' code=%d\n",
                     name ? name : "(null)", target.name, gai);
        return ret;
    }
    for (res = result; res; res = res->ai_next) {
        if (res->ai_family == AF_INET) {
            struct in_addr* addr = &((struct sockaddr_in*)res->ai_addr)->sin_addr;
            printf("--- IPv4 address: %s\n", inet_ntoa(*addr));
            ret = ntohl((*addr).s_addr);
            VMRP_NET_LOG("get_host result name='%s' ip=%s/0x%X\n",
                         name ? name : "(null)", inet_ntoa(*addr), (unsigned)ret);
            break;
        }
    }
    freeaddrinfo(result);
#else
    struct hostent* remoteHost = gethostbyname(target.name);
    if (remoteHost != NULL) {
        if (remoteHost->h_addrtype == AF_INET) {
            if (remoteHost->h_addr_list[0] != NULL) {
                struct in_addr addr;
                addr.s_addr = *(u_long*)remoteHost->h_addr_list[0];
                printf("%s\n", inet_ntoa(addr));
                ret = ntohl(addr.s_addr);
            }
        }
    }
#endif
    if (ret != MR_FAILED && target.hasPort) {
        uint32_t routeToken;
        if (createDnsMappedRoute(&target, (uint32_t)ret, &routeToken) != MR_SUCCESS) {
            VMRP_NET_LOG("dns_route creation failed or lookup became stale\n");
            return MR_FAILED;
        }
        VMRP_NET_LOG("get_host route name='%s' real_ip=0x%X token=0x%X\n",
                     name, (unsigned)ret, (unsigned)routeToken);
        return (int32)routeToken;
    }
    return ret;
}

static VMRP_THREAD_RET my_getHostByNameAsync(void* arg) {
    getHostByNameAsyncData_t* data = (getHostByNameAsyncData_t*)arg;
    int32 r = my_getHostByNameSync(data->name);
    printf("my_getHostByNameAsync(): 0x%X\n", r);
    /* 同 my_initNetworkAsync:guest 32 位地址显式经 uintptr_t 截断 */
    bridge_dsm_network_cb(data->uc, (uint32_t)(uintptr_t)data->cb, r,
                          (uint32_t)(uintptr_t)data->userData);
    free(data->name);
    free(data);
    return VMRP_THREAD_DONE;
}

/*
   MR_FAILED （立即感知的）失败，不再调用cb
   MR_WAITING 使用回调函数通知引擎获取IP的结果
   其他值 同步模式，立即返回的IP地址，不再调用cb 
*/
int32 my_getHostByName(uc_engine* uc, const char* name, MR_GET_HOST_CB cb, void* userData) {
    printf("my_getHostByName\n");
    printf("my_getHostByName('%s', 0x%p)\n", name, cb);
    VMRP_NET_LOG("my_get_host name='%s' cb=%p\n", name ? name : "(null)", (void*)cb);
    if (cb != NULL) {
        getHostByNameAsyncData_t* data = malloc(sizeof(getHostByNameAsyncData_t));
        int len = strlen(name);
        data->name = malloc(len + 1);
        strcpy(data->name, name);
        data->name[len] = '\0';
        data->cb = cb;
        data->userData = userData;
        data->uc = uc;
        if (startDetachedThread(&data->th, my_getHostByNameAsync, data) != MR_SUCCESS) {
            free(data->name);
            free(data);
            return MR_FAILED;
        }
        return MR_WAITING;
    }
    return my_getHostByNameSync(name);
}

// 返回-1表示失败，0表示不可写，1表示可写
int checkWritable(SOCKET_T socket) {
    fd_set writefds;
    FD_ZERO(&writefds);
    FD_SET(socket, &writefds);

    struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = 1000 * 50  // 50ms
    };

    SOCKET_T max_sd = socket;
    int ret = select(max_sd + 1, NULL, &writefds, NULL, &timeout);
    if (ret == 0) {  // timeout
        return 0;
    } else if (ret == -1) {
        return -1;
    }

    if (FD_ISSET(socket, &writefds)) {
        return 1;
    }
    return 0;
}

int32 my_sendto(int32 s, const char* buf, int len, int32 ip, uint16 port) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* data = (mSocket*)obj->data;
    if (applyDnsMappedRoute(&ip, &port) == DNS_ROUTE_ERROR) {
        return MR_FAILED;
    }

    struct sockaddr_in to;
    to.sin_family = AF_INET;
    to.sin_port = htons(port);
    to.sin_addr.s_addr = htonl(ip);

    printf("my_sendto(len:%d, '%s:%d')\n", len, inet_ntoa(to.sin_addr), port);

    int ret = sendto(data->s, buf, len, 0, (struct sockaddr*)&to, sizeof(to));
    if (ret == -1) {
        return MR_FAILED;
    }
    return ret;
}

/*
   >=0 实际发送的数据字节个数
   MR_FAILED Socket已经被关闭或遇到了无法修复的错误。 
*/
int32 my_send(int32 s, const char* buf, int len) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* data = (mSocket*)obj->data;

    data->sendCounter++;
    if (data->cmwapMode) {  // cmwap模式需要通过代理，这里模拟代理的功能
        printf("[my_send] cmwap on.\n");
        printf("[my_send] realState:%d.\n", data->realState);
        if (data->realState == MR_WAITING) {
            printf("[my_send] sendCounter:%d.\n", data->sendCounter);
            if (data->sendCounter == 1) {  // 第一次发送数据，尝试连接
                char host[256];
                uint16_t port;
                if (parseHostPort(buf, len, host, sizeof(host), &port) == MR_FAILED) {
                    printf("[my_send] Failed to parse host.\n");
                    return MR_FAILED;
                }
                int32 ip = my_getHostByNameSync(host);
                if (ip == MR_FAILED) {
                    printf("[my_send] Failed to get ip.\n");
                    return MR_FAILED;
                }
                if (my_connect(s, ip, port, MR_SOCKET_BLOCK) == MR_FAILED) {
                    printf("[my_send] Failed to connect to ip.\n");
                    return MR_FAILED;
                }
                data->realState = MR_SUCCESS;
            }
            /* The CMWAP bridge resolves the proxy target and connects with a
             * blocking call above.  The socket is writable now, so send the
             * original request in this mr_send call; returning zero would make
             * one-shot HTTP downloaders wait for a retry that may never occur. */
        } else if (data->realState == MR_FAILED) {
            printf("[my_send] realState MR_FAILED\n");
            return MR_FAILED;
        }
    } else {
        printf("[my_send] cmwap off.\n");
    }
    int ret = checkWritable(data->s);
    if (ret == -1) {
        return MR_FAILED;
    } else if (ret == 0) {
        return 0;
    }
    ret = send(data->s, buf, len, 0);
    printf("my_send(s:%d, fd:%d, len:%d): sent=%d, errno=%d\n", s, (int)data->s, len, ret, errno);
    printf("[my_send] data: %s\n", buf);
    if (ret == -1) {
        return MR_FAILED;
    }
    return ret;
}

// 返回-1表示失败，0表示不可读，1表示可读
int checkReadable(SOCKET_T socket) {
    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(socket, &readfds);

    struct timeval timeout = {
        .tv_sec = 0,
        .tv_usec = 1000 * 50  // 50ms
    };

    SOCKET_T max_sd = socket;
    int ret = select(max_sd + 1, &readfds, NULL, NULL, &timeout);
    if (ret == 0) {  // timeout
        return 0;
    } else if (ret == -1) {
        return -1;
    }
    if (FD_ISSET(socket, &readfds)) {
        return 1;
    }
    return 0;
}

int32 my_recvfrom(int32 s, char* buf, int len, int32* ip, uint16* port) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* data = (mSocket*)obj->data;
    int ret = checkReadable(data->s);
    if (ret == -1) {
        return MR_FAILED;
    } else if (ret == 0) {
        return 0;
    }
    struct sockaddr_in from;
    socklen_t fromLen = sizeof(from);
    ret = recvfrom(data->s, buf, len, 0, (struct sockaddr*)&from, &fromLen);
    if (ret == -1) {
        return MR_FAILED;
    }

    if (from.sin_family != AF_INET) {
        printf("warning my_recvfrom() recv not ipv4\n");
    }
    *port = ntohs(from.sin_port);
    *ip = ntohl(from.sin_addr.s_addr);
    printf("my_recvfrom(len:%d, '%s:%d')\n", len, inet_ntoa(from.sin_addr), *port);

    return ret;
}

/*
   >=0的整数 实际接收的数据字节个数
   MR_FAILED Socket已经被关闭或遇到了无法修复的错误。 
*/
int32 my_recv(int32 s, char* buf, int len) {
    uIntMap* obj = uIntMap_search(&sockets, (uint32_t)s);
    mSocket* data = (mSocket*)obj->data;
    if (data->realState == MR_WAITING) {
        return 0;
    }
    if (data->realState == MR_FAILED) {
        return MR_FAILED;
    }
    // cmwap模式：真实连接建立后，伪造代理的"200 Connection established"响应
    // if (isCMWAP && data->cmwapProxyAck) {
    //     static const char fakeResp[] = "HTTP/1.0 200 Connection established\r\n\r\n";
    //     int respLen = (int)(sizeof(fakeResp) - 1);
    //     if (len >= respLen) {
    //         memcpy(buf, fakeResp, respLen);
    //         data->cmwapProxyAck = 0;
    //         printf("my_recv: injected CMWAP fake proxy ack\n");
    //         return respLen;
    //     }
    // }
    int ret = checkReadable(data->s);
    printf("my_recv(s:%d, fd:%d, len:%d): checkReadable=%d\n", s, (int)data->s, len, ret);
    if (ret == -1) {
        return MR_FAILED;
    } else if (ret == 0) {
        return 0;
    }
    ret = recv(data->s, buf, len, 0);
    printf("my_recv(s:%d): recv=%d, errno=%d\n", s, ret, errno);
    if (ret == 0) {
        /*
         * select()+readable followed by recv()==0 is TCP FIN, not "no data".
         * Mythroad sockets use 0 for temporary EAGAIN-style polling; keeping a
         * closed socket in that state makes browser/update state machines spin
         * forever instead of completing their response parse.
         */
        my_closeSocket(s);
        return MR_FAILED;
    }
    if (ret > 0) {
        char preview[65];
        int plen = ret < 64 ? ret : 64;
        memcpy(preview, buf, plen);
        preview[plen] = '\0';
        printf("my_recv data: [%s]\n", preview);
    }
    if (ret == -1) {
        return MR_FAILED;
    }
    return ret;
}
