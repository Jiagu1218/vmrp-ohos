/**
 * StoreService.ets - 商店 API 服务层
 *
 * 通过 RCP (@kit.RemoteCommunicationKit) 与 store_server 通信。
 * 所有 API 使用统一响应格式 {"code":0,"data":{...}}。
 * 服务器地址从 Preferences 读取（key: store_server_url）。
 */
import { rcp } from '@kit.RemoteCommunicationKit';
import { preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { gAbilityContext } from '../entryability/EntryAbility';
import {
  StoreApp, StoreAppDetail, StoreFileGroup, StoreFile,
  StoreListResponse, StoreUploadResponse, StoreRateResponse
} from '../model/StoreModel';

const PREF_NAME = 'vmrp_settings';
const KEY_STORE_URL = 'store_server_url';
const TAG = 'StoreService';

/** MRP 文件魔数 "MRPG" (0x4D525047) 的前4字节 */
const MRPG_MAGIC: number[] = [0x4D, 0x52, 0x50, 0x47];

export class StoreService {
  private static session: rcp.Session | null = null;

  // ========== Session 管理 ==========

  static createSession(): rcp.Session {
    if (StoreService.session === null) {
      const securityConfig: rcp.SecurityConfiguration = {
        remoteValidation: 'skip'
      };
      const requestConfig: rcp.Configuration = {
        security: securityConfig
      };
      const sessionConfig: rcp.SessionConfiguration = {
        requestConfiguration: requestConfig
      };
      StoreService.session = rcp.createSession(sessionConfig);
    }
    return StoreService.session;
  }

  static destroySession(): void {
    if (StoreService.session !== null) {
      try {
        StoreService.session.close();
      } catch (_e) {}
      StoreService.session = null;
    }
  }

  /** 创建带进度回调的临时 session（用于 downloadToFile / uploadFromFile） */
  static createSessionWithProgress(handler: rcp.HttpEventsHandler): rcp.Session {
    const securityConfig: rcp.SecurityConfiguration = {
      remoteValidation: 'skip'
    };
    const requestConfig: rcp.Configuration = {
      tracing: {
        httpEventsHandler: handler
      },
      security: securityConfig
    };
    const config: rcp.SessionConfiguration = {
      requestConfiguration: requestConfig
    };
    return rcp.createSession(config);
  }

  // ========== 核心配置 ==========

  static getServerUrl(): string {
    const ctx = gAbilityContext;
    if (!ctx) return '';
    try {
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      return pref.getSync(KEY_STORE_URL, '') as string;
    } catch (_e) {
      return '';
    }
  }

  static setServerUrl(url: string): void {
    const ctx = gAbilityContext;
    if (!ctx) return;
    try {
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(KEY_STORE_URL, url);
      pref.flush();
    } catch (_e) {}
  }

  static buildUrl(path: string): string {
    const base = StoreService.getServerUrl();
    if (base.length === 0) return '';
    const sep = base.endsWith('/') ? '' : '/';
    return `${base}${sep}${path}`;
  }

  static iconUrl(appid: string): string {
    return StoreService.buildUrl(`api/icon/${appid}`);
  }

  // ========== API 请求 ==========

  /** 从 RCP Response 中提取业务数据（使用 response.toJSON()） */
  private static extractData(resp: rcp.Response): Record<string, Object> | null {
    try {
      const json = resp.toJSON();
      if (json !== null && json !== undefined && typeof json === 'object') {
        return json as Record<string, Object>;
      }
    } catch (_e) {}
    return null;
  }

  /** 从业务数据中取出 code 字段 */
  private static getCode(data: Record<string, Object>): number {
    return (data['code'] ?? -1) as number;
  }

  /** 从业务数据中取出 data 字段 */
  private static getData(data: Record<string, Object>): Record<string, Object> | null {
    const d = data['data'];
    if (d !== null && d !== undefined && typeof d === 'object') {
      return d as Record<string, Object>;
    }
    return null;
  }

  /** 将服务端返回的 app 对象转换为 StoreApp（字段类型适配：appid number→string, vendor null→空串） */
  private static parseStoreApp(raw: Record<string, Object>): StoreApp {
    return {
      appid: `${raw['appid'] ?? ''}`,
      name: `${raw['name'] ?? ''}`,
      vendor: raw['vendor'] !== null && raw['vendor'] !== undefined ? `${raw['vendor']}` : '',
      size: (raw['size'] ?? 0) as number,
      has_icon: !!raw['has_icon'],
      rating: (raw['rating'] ?? 0) as number,
      rating_count: (raw['rating_count'] ?? 0) as number,
      resolutions: (raw['resolutions'] ?? []) as string[],
    };
  }

  /** 将服务端返回的 app 详情对象转换为 StoreAppDetail */
  private static parseStoreAppDetail(raw: Record<string, Object>): StoreAppDetail {
    const fileGroups: StoreFileGroup[] = [];
    const files = raw['files'];
    if (files !== null && files !== undefined && typeof files === 'object') {
      const filesObj = files as Record<string, Object>;
      const keys = Object.keys(filesObj);
      for (const key of keys) {
        const group = filesObj[key];
        if (group !== null && group !== undefined && typeof group === 'object') {
          const g = group as Record<string, Object>;
          const res = g['resolution'] !== undefined ? `${g['resolution']}` : key;
          const versions = g['versions'];
          const versionList: StoreFile[] = [];
          if (Array.isArray(versions)) {
            for (const v of versions as Object[]) {
              const vf = v as Record<string, Object>;
              versionList.push({
                width: (vf['width'] ?? 0) as number,
                height: (vf['height'] ?? 0) as number,
                version: (vf['version'] ?? 0) as number,
                filename: `${vf['filename'] ?? ''}`,
                realname: `${vf['realname'] ?? ''}`,
                size: (vf['size'] ?? 0) as number,
                md5: `${vf['md5'] ?? ''}`,
                is_latest: !!vf['is_latest'],
              });
            }
          }
          fileGroups.push({ resolution: res, versions: versionList });
        }
      }
    }
    return {
      appid: `${raw['appid'] ?? ''}`,
      name: `${raw['name'] ?? ''}`,
      vendor: raw['vendor'] !== null && raw['vendor'] !== undefined ? `${raw['vendor']}` : '',
      desc: `${raw['desc'] ?? ''}`,
      rating: (raw['rating'] ?? 0) as number,
      rating_count: (raw['rating_count'] ?? 0) as number,
      has_icon: !!raw['has_icon'],
      files: fileGroups,
    };
  }

  static async listApps(page: number, size: number, res?: string, vendor?: string,
    appid?: string, name?: string): Promise<StoreListResponse> {
    const params: string[] = [];
    params.push(`page=${page}`);
    params.push(`size=${size}`);
    if (res && res.length > 0) params.push(`res=${encodeURIComponent(res)}`);
    if (vendor && vendor.length > 0) params.push(`vendor=${encodeURIComponent(vendor)}`);
    if (appid && appid.length > 0) params.push(`appid=${encodeURIComponent(appid)}`);
    if (name && name.length > 0) params.push(`name=${encodeURIComponent(name)}`);
    const url = StoreService.buildUrl(`api/apps?${params.join('&')}`);
    if (url.length === 0) {
      return { total: 0, page: 0, size: size, vendor: '', items: [] };
    }
    const session = StoreService.createSession();
    const req = new rcp.Request(url, 'GET');
    req.headers = { 'Accept': 'application/json' };
    try {
      const resp = await session.fetch(req);
      if (resp.statusCode === 200) {
        const raw = StoreService.extractData(resp);
        if (raw !== null && StoreService.getCode(raw) === 0) {
          const data = StoreService.getData(raw);
          if (data !== null) {
            const rawItems = data['items'];
            const items: StoreApp[] = [];
            if (Array.isArray(rawItems)) {
              for (const item of rawItems as Object[]) {
                items.push(StoreService.parseStoreApp(item as Record<string, Object>));
              }
            }
            return {
              total: (data['total'] ?? 0) as number,
              page: (data['page'] ?? 0) as number,
              size: (data['size'] ?? size) as number,
              vendor: data['vendor'] !== null && data['vendor'] !== undefined ? `${data['vendor']}` : '',
              items: items,
            };
          }
        }
      }
      return { total: 0, page: 0, size: size, vendor: '', items: [] };
    } catch (e) {
      console.error(`${TAG}: listApps failed: ${e}`);
      return { total: 0, page: 0, size: size, vendor: '', items: [] };
    }
  }

  static async listVendors(): Promise<string[]> {
    const url = StoreService.buildUrl('api/vendors');
    if (url.length === 0) return [];
    const session = StoreService.createSession();
    const req = new rcp.Request(url, 'GET');
    req.headers = { 'Accept': 'application/json' };
    try {
      const resp = await session.fetch(req);
      if (resp.statusCode === 200) {
        const raw = StoreService.extractData(resp);
        if (raw !== null && StoreService.getCode(raw) === 0) {
          const data = StoreService.getData(raw);
          if (data !== null) {
            const v = data['vendors'];
            if (Array.isArray(v)) {
              const result: string[] = [];
              for (const item of v as Object[]) {
                result.push(`${item}`);
              }
              return result;
            }
          }
        }
      }
      return [];
    } catch (_e) {
      return [];
    }
  }

  static async appDetail(appid: string): Promise<StoreAppDetail | null> {
    const url = StoreService.buildUrl(`api/app/${appid}`);
    if (url.length === 0) return null;
    const session = StoreService.createSession();
    const req = new rcp.Request(url, 'GET');
    req.headers = { 'Accept': 'application/json' };
    try {
      const resp = await session.fetch(req);
      if (resp.statusCode === 200) {
        const raw = StoreService.extractData(resp);
        if (raw !== null && StoreService.getCode(raw) === 0) {
          const data = StoreService.getData(raw);
          if (data !== null) {
            return StoreService.parseStoreAppDetail(data);
          }
        }
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  static async addRating(appid: string, score: number): Promise<StoreRateResponse | null> {
    const url = StoreService.buildUrl(`api/rate/${appid}`);
    if (url.length === 0) return null;
    const session = StoreService.createSession();
    const req = new rcp.Request(url, 'POST');
    req.headers = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
    const body: Record<string, number> = { 'score': score };
    req.content = JSON.stringify(body);
    try {
      const resp = await session.fetch(req);
      if (resp.statusCode === 200) {
        const raw = StoreService.extractData(resp);
        if (raw !== null && StoreService.getCode(raw) === 0) {
          const data = StoreService.getData(raw);
          if (data !== null) {
            return {
              appid: `${data['appid'] ?? ''}`,
              rating: (data['rating'] ?? 0) as number,
            };
          }
        }
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  // ========== 文件操作 ==========

  static async downloadMrp(appid: string, res: string, version?: number,
    onProgress?: (progress: number) => void): Promise<string> {
    const ctx = gAbilityContext;
    if (!ctx) throw new Error('No context');
    const mythroadDir = `${ctx.filesDir}/mythroad`;
    // 构建 URL
    const params: string[] = [];
    params.push(`res=${encodeURIComponent(res)}`);
    if (version !== undefined && version > 0) params.push(`version=${version}`);
    const url = StoreService.buildUrl(`api/download/${appid}?${params.join('&')}`);
    if (url.length === 0) throw new Error('Server URL not configured');

    // 确保目录存在
    try {
      if (!fs.accessSync(mythroadDir)) {
        fs.mkdirSync(mythroadDir, true);
      }
    } catch (_e) {}

    // 目标路径：使用 appid_res_version.mrp 命名
    const versionSuffix = version !== undefined && version > 0 ? `_v${version}` : '';
    const fileName = `${appid}_${res}${versionSuffix}.mrp`;
    const destPath = `${mythroadDir}/${fileName}`;

    // 检查文件是否已存在
    try {
      if (fs.accessSync(destPath)) {
        return destPath;
      }
    } catch (_e) {}

    // 使用 downloadToFile API
    const session = StoreService.createSession();
    const downloadCfg: rcp.DownloadToFile = {
      kind: 'file',
      file: destPath
    };
    // 通过 httpEventsHandler 监听进度
    const httpEventsHandler: rcp.HttpEventsHandler = {
      onDownloadProgress: (totalSize: number, transferredSize: number) => {
        if (onProgress && totalSize > 0) {
          onProgress(transferredSize / totalSize);
        }
      }
    };
    const reqConfig: rcp.Configuration = {
      tracing: {
        httpEventsHandler: httpEventsHandler
      }
    };
    try {
      // downloadToFile takes URLOrString (not Request), progress via session config
      const sessionWithProgress = StoreService.createSessionWithProgress(httpEventsHandler);
      await sessionWithProgress.downloadToFile(url, downloadCfg);
      return destPath;
    } catch (e) {
      // 下载失败时清理部分文件
      try { fs.unlinkSync(destPath); } catch (_e2) {}
      throw new Error(`Download failed: ${JSON.stringify(e)}`);
    }
  }

  static async uploadMrp(filePath: string, width: number, height: number,
    onProgress?: (progress: number) => void): Promise<StoreUploadResponse | null> {
    const url = StoreService.buildUrl('api/upload');
    if (url.length === 0) return null;

    // 本地校验 MRP 文件头（MRPG magic）
    try {
      const f = fs.openSync(filePath, fs.OpenMode.READ_ONLY);
      const buf = new ArrayBuffer(4);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      const u8 = new Uint8Array(buf);
      for (let i = 0; i < 4; i++) {
        if (u8[i] !== MRPG_MAGIC[i]) {
          return null;
        }
      }
    } catch (_e) {
      return null;
    }

    const session = StoreService.createSession();

    // 构建 multipart form — contentOrPath 字段
    // 文件字段：contentOrPath 为文件路径字符串 (rcp.Path = string)
    // 文本字段：contentOrPath 也为字符串
    const fileFieldValue: rcp.MultipartFormFieldValue = {
      remoteFileName: filePath.split('/').pop() || 'upload.mrp',
      contentType: 'application/octet-stream',
      contentOrPath: filePath
    };
    const widthFieldValue: rcp.MultipartFormFieldValue = {
      contentType: 'text/plain',
      contentOrPath: `${width}`
    };
    const heightFieldValue: rcp.MultipartFormFieldValue = {
      contentType: 'text/plain',
      contentOrPath: `${height}`
    };
    const formFields: Record<string, rcp.MultipartFormFieldValue> = {
      'file': fileFieldValue,
      'width': widthFieldValue,
      'height': heightFieldValue
    };
    const form = new rcp.MultipartForm(formFields);

    const httpEventsHandler: rcp.HttpEventsHandler = {
      onUploadProgress: (totalSize: number, transferredSize: number) => {
        if (onProgress && totalSize > 0) {
          onProgress(transferredSize / totalSize);
        }
      }
    };

    const req = new rcp.Request(url, 'POST');
    req.headers = { 'Accept': 'application/json' };
    req.content = form;
    req.configuration = {
      tracing: {
        httpEventsHandler: httpEventsHandler
      }
    };
    try {
      const resp = await session.fetch(req);
      if (resp.statusCode === 200) {
        const raw = StoreService.extractData(resp);
        if (raw !== null && StoreService.getCode(raw) === 0) {
          const data = StoreService.getData(raw);
          if (data !== null) {
            const result: StoreUploadResponse = {
              appid: `${data['appid'] ?? ''}`,
              width: (data['width'] ?? 0) as number,
              height: (data['height'] ?? 0) as number,
              version: (data['version'] ?? 0) as number,
              size: (data['size'] ?? 0) as number,
            };
            return result;
          }
        }
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  // ========== 辅助 ==========

  static async checkConnection(): Promise<boolean> {
    const url = StoreService.buildUrl('api/vendors');
    if (url.length === 0) return false;
    const session = StoreService.createSession();
    const req = new rcp.Request(url, 'GET');
    req.headers = { 'Accept': 'application/json' };
    try {
      const resp = await session.fetch(req);
      return resp.statusCode === 200;
    } catch (_e) {
      return false;
    }
  }
}
