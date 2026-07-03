/*
 * libentry.so 的 ArkTS 类型声明。
 * 对应 entry/src/main/cpp/vmrp_napi.cpp 中 napi_define_properties 注册的方法。
 * ArkTS 通过 import { ... } from 'libentry.so' 导入，本声明让编译器识别类型。
 */
export const loadLib: (soPath: string) => boolean;
export const init: (width: number, height: number) => number;
export const setWorkDir: (dir: string) => number;
export const start: (mrpPath: string, ext: string, entry: string) => number;
export const stop: () => void;
export const sendKey: (type: number, key: number) => number;
export const submitEdit: (text: string) => number;
export const cancelEdit: () => number;
export const isRunning: () => boolean;
export const setEditCallback: (cb: () => void) => void;
export const createSurfaceNode: (nodeContent: object) => void;
