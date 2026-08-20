/**
 * StoreModel.ets - 商店数据模型
 *
 * 定义商店 API 响应的数据接口，与 store_server API 契约对齐。
 * 统一响应格式: {"code":0,"data":{...}} 成功 / {"code":HTTP_STATUS,"msg":"..."} 失败
 */

/** 商店应用列表条目 */
export interface StoreApp {
  appid: string;
  name: string;
  vendor: string;
  size: number;
  has_icon: boolean;
  rating: number;
  rating_count: number;
  resolutions: string[];
}

/** 应用详情 */
export interface StoreAppDetail {
  appid: string;
  name: string;
  vendor: string;
  desc: string;
  rating: number;
  rating_count: number;
  has_icon: boolean;
  files: StoreFileGroup[];
}

/** 按分辨率分组的文件列表 */
export interface StoreFileGroup {
  resolution: string;
  versions: StoreFile[];
}

/** 单个版本文件信息 */
export interface StoreFile {
  width: number;
  height: number;
  version: number;
  filename: string;
  realname: string;
  size: number;
  md5: string;
  is_latest: boolean;
}

/** 统一 API 响应格式 */
export interface ApiResponse<T> {
  code: number;
  data: T | null;
  msg: string;
}

/** 应用列表响应数据 */
export interface StoreListResponse {
  total: number;
  page: number;
  size: number;
  vendor: string;
  items: StoreApp[];
}

/** 厂商列表响应数据 */
export interface StoreVendorsResponse {
  vendors: string[];
}

/** 上传成功响应数据 */
export interface StoreUploadResponse {
  appid: string;
  width: number;
  height: number;
  version: number;
  size: number;
}

/** 评分响应数据 */
export interface StoreRateResponse {
  appid: string;
  rating: number;
}

/** 统计响应数据 */
export interface StoreStatsResponse {
  apps: number;
  files: number;
}
