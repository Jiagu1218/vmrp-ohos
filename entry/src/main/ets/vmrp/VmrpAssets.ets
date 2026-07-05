/*
 * VmrpAssets.ets - mythroad 运行时资源管理。
 *
 * 首次启动时把 rawfile 中的 mythroad 运行时（dsm_gm.mrp、字体 gb12/gb16.uc2、
 * plugins 等，含 system/ 等任意子目录）解压到应用沙箱工作目录；同时把用户
 * 选择的 .mrp 游戏文件复制进去。
 *
 * 资源清单不再硬编码：通过 resourceManager.getRawFileList 递归遍历
 * rawfile/mythroad/ 下所有文件（含子文件夹）。
 *
 * vmrp 的工作目录即 MRP 文件所在目录（vmrp/docs/flutter-integration.md）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const TAG = 'VmrpAssets';
// rawfile 中 mythroad 资源根目录（相对 rawfile，无前后斜杠）。
const RAW_MYTHROAD_ROOT = 'mythroad';

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

  // 递归遍历 rawfile 中的目录，把所有文件拷贝到沙箱，保留目录结构。
  //
  // HarmonyOS 的 getRawFileList(path) 只列出该层条目，不递归、且不区分
  // 文件/目录。这里用「尝试 getRawFileContent」来区分：成功即为文件（顺带
  // 拿到内容直接写入沙箱，避免二次读取），失败则视作子目录继续递归。
  //
  // rawDir：相对 rawfile 的目录路径，如 'mythroad' 或 'mythroad/system'。
  // mythroadDir：沙箱目标根（files/mythroad）。
  // 返回本次成功拷贝的文件数。
  private static async dumpRawDir(ctx: common.UIAbilityContext,
                                  rawDir: string,
                                  mythroadDir: string): Promise<number> {
    // 确保沙箱侧当前层目录存在：顶层（mythroad）由调用方 getWorkDir 保证；
    // 子层（如 mythroad/system）首次进入时这里补建，写入本层文件时即合法。
    const relDir = rawDir.startsWith(`${RAW_MYTHROAD_ROOT}/`)
      ? rawDir.substring(RAW_MYTHROAD_ROOT.length + 1) : '';
    const dstRoot = relDir.length > 0 ? `${mythroadDir}/${relDir}` : mythroadDir;
    try {
      if (!fs.accessSync(dstRoot)) {
        fs.mkdirSync(dstRoot, true);
      }
    } catch (e) { /* 目录可能已存在 */ }

    let entries: string[] = [];
    try {
      entries = await ctx.resourceManager.getRawFileList(rawDir);
    } catch (e) {
      // 该路径不是目录或不存在，交给调用方判断（顶层不应发生）。
      return 0;
    }
    let copied = 0;
    for (const name of entries) {
      if (!name) continue;
      // 拼接下层相对路径，e.g. 'mythroad/system/gb12.uc2'。
      const rawPath = `${rawDir}/${name}`;
      // 相对 mythroad 根的路径（去掉前导 'mythroad/'）。
      const rel = rawPath.startsWith(`${RAW_MYTHROAD_ROOT}/`)
        ? rawPath.substring(RAW_MYTHROAD_ROOT.length + 1) : rawPath;
      // 先尝试当作文件读取：成功则直接拷贝。
      let buf: Uint8Array | null = null;
      try {
        buf = await ctx.resourceManager.getRawFileContent(rawPath);
      } catch (e) {
        buf = null;
      }
      if (buf !== null) {
        const dst = `${mythroadDir}/${rel}`;
        // 确保目标父目录存在（支持任意层级子目录）。
        const slash = rel.lastIndexOf('/');
        if (slash >= 0) {
          const dstDir = `${mythroadDir}/${rel.substring(0, slash)}`;
          try {
            if (!fs.accessSync(dstDir)) {
              fs.mkdirSync(dstDir, true);
            }
          } catch (e) { /* 目录可能已存在 */ }
        }
        try {
          const file = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.writeSync(file.fd, buf.buffer);
          fs.closeSync(file);
          copied++;
        } catch (e) {
          console.error(`${TAG}: copy ${rel} failed: ${JSON.stringify(e)}`);
        }
      } else {
        // 不是文件，按子目录递归。
        copied += await VmrpAssets.dumpRawDir(ctx, rawPath, mythroadDir);
      }
    }
    return copied;
  }

  // 确保 mythroad 运行时资源存在于 files/mythroad/。首次调用时从 rawfile 解压。
  static async ensureRuntime(ctx: common.UIAbilityContext): Promise<string> {
    // getWorkDir 会创建 files/mythroad，dumpRawDir 写顶层文件（如 dsm_gm.mrp）
    // 时依赖该目录已存在，否则 openSync 报 ENOENT。
    VmrpAssets.getWorkDir(ctx);
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
      try {
        const n = await VmrpAssets.dumpRawDir(ctx, RAW_MYTHROAD_ROOT, mythroadDir);
        console.info(`${TAG}: installed ${n} mythroad assets`);
      } catch (e) {
        console.error(`${TAG}: dumpRawDir failed: ${JSON.stringify(e)}`);
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
