import { fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';

export interface MrpInfoData {
  filename: string;
  appname: string;
  appid: number;
  version: number;
  vendor: string;
  description: string;
  screenW: number;
  screenH: number;
  platform: number;
  fileSize: number;
  filePath: string;
  mtime: number;
}

const MRP_MAGIC = 'MRPG';
const MRP_HEAD_SIZE = 240;

export class MrpInfo {
  static parse(filePath: string): MrpInfoData | null {
    let fd: number = -1;
    try {
      fd = fs.openSync(filePath, fs.OpenMode.READ_ONLY).fd;
      const buf = new ArrayBuffer(MRP_HEAD_SIZE);
      fs.readSync(fd, buf, { offset: 0, length: MRP_HEAD_SIZE });
      const view = new DataView(buf);

      const magic = MrpInfo.readString(view, 0, 4);
      if (magic !== MRP_MAGIC) {
        return null;
      }

      const fileLen = view.getUint32(8, true);
      const filename = MrpInfo.readString(view, 16, 12);
      const appname = MrpInfo.decodeGbk(view, 28, 24);
      const appid = view.getUint32(68, true);
      const version = view.getUint32(72, true);
      const vendor = MrpInfo.decodeGbk(view, 88, 40);
      const description = MrpInfo.decodeGbk(view, 128, 64);

      let screenW = 240;
      let screenH = 320;
      let platform = 1;
      if (MRP_HEAD_SIZE >= 210) {
        screenW = view.getUint16(204, true);
        screenH = view.getUint16(206, true);
        platform = view.getUint8(208);
        if (screenW === 0 || screenH === 0) {
          screenW = 240;
          screenH = 320;
        }
      }

      const slash = filePath.lastIndexOf('/');
      const baseName = slash >= 0 ? filePath.substring(slash + 1) : filePath;

      let mtime = 0;
      try {
        const stat = fs.statSync(filePath);
        mtime = stat.mtime;
      } catch (_e) {}

      const result: MrpInfoData = {
        filename: filename.length > 0 ? filename : baseName,
        appname: appname.length > 0 ? appname : baseName.replace('.mrp', ''),
        appid: appid,
        version: version,
        vendor: vendor,
        description: description,
        screenW: screenW,
        screenH: screenH,
        platform: platform,
        fileSize: fileLen,
        filePath: filePath,
        mtime: mtime
      };
      return result;
    } catch (_e) {
      return null;
    } finally {
      if (fd >= 0) {
        try { fs.closeSync(fd); } catch (_e) {}
      }
    }
  }

  private static readString(view: DataView, offset: number, maxLen: number): string {
    const bytes: number[] = [];
    for (let i = 0; i < maxLen; i++) {
      const b = view.getUint8(offset + i);
      if (b === 0) break;
      bytes.push(b);
    }
    if (bytes.length === 0) return '';
    let s = '';
    for (const b of bytes) {
      s += String.fromCharCode(b);
    }
    return s;
  }

  private static decodeGbk(view: DataView, offset: number, maxLen: number): string {
    const bytes: number[] = [];
    for (let i = 0; i < maxLen; i++) {
      const b = view.getUint8(offset + i);
      if (b === 0) break;
      bytes.push(b);
    }
    if (bytes.length === 0) return '';
    try {
      const arr = new Uint8Array(bytes.length);
      for (let i = 0; i < bytes.length; i++) {
        arr[i] = bytes[i];
      }
      const decoder = util.TextDecoder.create('gbk');
      return decoder.decodeToString(arr);
    } catch (_e) {
      return MrpInfo.readString(view, offset, maxLen);
    }
  }
}
