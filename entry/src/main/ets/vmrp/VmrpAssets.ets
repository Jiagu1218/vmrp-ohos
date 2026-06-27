/*
 * VmrpAssets.ets - mythroad 运行时资源管理。
 *
 * 首次启动时把 rawfile 中的 mythroad 运行时（dsm_gm.mrp、字体 gb12/gb16.uc2、
 * plugins 等）解压到应用沙箱工作目录；同时把用户选择的 .mrp 游戏文件复制进去。
 *
 * vmrp 的工作目录即 MRP 文件所在目录（vmrp/docs/flutter-integration.md）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const TAG = 'VmrpAssets';

// rawfile 中的 mythroad 资源清单（相对 rawfile/mythroad/ 的路径）。
const MYTHROAD_FILES: string[] = [
  'dsm_gm.mrp',
  'system/gb12.uc2',
  'system/gb16.uc2',
];

export class VmrpAssets {
  // 获取沙箱工作目录（files 根）。
  // vmrp 的 dsmWorkPath 默认 "mythroad/"，它会拼接成 mythroad/<相对路径>，
  // 因此 chdir 目标应是 mythroad 的父目录（files），资源放在 files/mythroad/ 下。
  // 若 chdir 到 files/mythroad 反而会查找 files/mythroad/mythroad/... 多一层。
  static getWorkDir(ctx: common.UIAbilityContext): string {
    const base = ctx.filesDir;
    // 确保 files/mythroad 子目录存在（资源解压目标）。
    try {
      if (!fs.accessSync(`${base}/mythroad`)) {
        fs.mkdirSync(`${base}/mythroad`, true);
      }
    } catch (e) {
      console.error(`${TAG}: mkdir mythroad failed: ${JSON.stringify(e)}`);
    }
    return base;
  }

  // 获取 mythroad 资源目录（files/mythroad），mrp 和 system 在此。
  static getMythroadDir(ctx: common.UIAbilityContext): string {
    return `${ctx.filesDir}/mythroad`;
  }

  // 确保 mythroad 运行时资源存在于 files/mythroad/。首次调用时从 rawfile 解压。
  static async ensureRuntime(ctx: common.UIAbilityContext): Promise<string> {
    const mythroadDir = VmrpAssets.getMythroadDir(ctx);
    const marker = `${mythroadDir}/.installed`;
    // 用标记文件判断是否已解压（避免每次启动重复拷贝）。
    let needInstall = true;
    try {
      needInstall = !fs.accessSync(marker);
    } catch (e) {
      needInstall = true;
    }
    if (needInstall) {
      for (const rel of MYTHROAD_FILES) {
        const dst = `${mythroadDir}/${rel}`;
        const dstDir = rel.indexOf('/') >= 0 ?
          `${mythroadDir}/${rel.substring(0, rel.lastIndexOf('/'))}` : mythroadDir;
        try {
          if (!fs.accessSync(dstDir)) {
            fs.mkdirSync(dstDir, true);
          }
        } catch (e) { /* 目录可能已存在 */ }
        try {
          let exists = false;
          try { exists = fs.accessSync(dst); } catch (e) { exists = false; }
          if (!exists) {
            const buf: Uint8Array = await ctx.resourceManager.getRawFileContent(`mythroad/${rel}`);
            const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
            fs.writeSync(file.fd, buf.buffer);
            fs.closeSync(file);
          }
        } catch (e) {
          console.error(`${TAG}: copy ${rel} failed: ${JSON.stringify(e)}`);
        }
      }
      // 写标记文件。
      try {
        const f = fs.openSync(marker, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        fs.writeSync(f.fd, '1');
        fs.closeSync(f);
      } catch (e) { /* 忽略标记失败 */ }
    }
    return VmrpAssets.getWorkDir(ctx);
  }

  // 把用户选择的 MRP 文件复制到 mythroad 目录，返回目标路径。
  static async importMrp(ctx: common.UIAbilityContext, srcUri: string): Promise<string> {
    const mythroadDir = VmrpAssets.getMythroadDir(ctx);
    const name = srcUri.substring(srcUri.lastIndexOf('/') + 1);
    const dst = `${mythroadDir}/${name}`;
    try {
      const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      const dstFile = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      await fs.copyFile(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
    } catch (e) {
      console.error(`${TAG}: importMrp failed: ${JSON.stringify(e)}`);
    }
    return dst;
  }
}
