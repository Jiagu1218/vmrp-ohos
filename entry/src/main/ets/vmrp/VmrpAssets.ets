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
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';

const TAG = 'VmrpAssets';
// rawfile 中 mythroad 资源根目录（相对 rawfile，无前后斜杠）。
const RAW_MYTHROAD_ROOT = 'mythroad';

export class VmrpAssets {
  // 获取沙箱工作目录（files 根）。
  // vmrp 的 dsmWorkPath 默认 "mythroad/"，它会拼接成 mythroad/<相对路径>，
  // 因此 chdir 目标应是 mythroad 的父目录（files），资源放在 files/mythroad/ 下。
  // 若 chdir 到 files/mythroad 反而会查找 files/mythroad/mythroad/... 多一层。
  static getWorkDir(ctx: common.Context): string {
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
  static getMythroadDir(ctx: common.Context): string {
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
  private static async dumpRawDir(ctx: common.Context,
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
  static async ensureRuntime(ctx: common.Context): Promise<string> {
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

  // 清空 mythroad 工作目录（files/mythroad），含游戏、缓存、.installed 标记。
  // 下次 ensureRuntime 会重新从 rawfile 解压基础资源。用户导入的 mrp 和游戏
  // 生成的缓存（如 sky.bmp、avm_cache）都会被清除。返回 true 表示成功。
  static clearWorkDir(ctx: common.Context): boolean {
    const mythroadDir = VmrpAssets.getMythroadDir(ctx);
    try {
      if (!fs.accessSync(mythroadDir)) return true;
      // rmdirSync 不能删非空目录，需先递归删除所有内容。
      VmrpAssets.removeRecursive(mythroadDir);
    } catch (e) {
      console.error(`${TAG}: clearWorkDir failed: ${JSON.stringify(e)}`);
      return false;
    }
    return true;
  }

  // 递归删除目录及其所有内容（rmdirSync 只删空目录，需先清文件再删子目录）。
  private static removeRecursive(dir: string): void {
    const names: string[] = fs.listFileSync(dir);
    for (const name of names) {
      const child = `${dir}/${name}`;
      if (fs.statSync(child).isDirectory()) {
        VmrpAssets.removeRecursive(child);
      } else {
        fs.unlinkSync(child);
      }
    }
    fs.rmdirSync(dir);
  }

  // 把用户选择的 MRP 文件复制到 mythroad 目录，返回目标路径。
  static async importMrp(ctx: common.Context, srcUri: string): Promise<string> {
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

  // 批量导入 MRP 文件到 mythroad 目录。srcUris 为 picker 返回的 URI 数组。
  // 同名文件覆盖。返回成功导入的文件数。
  static async importMrpBatch(ctx: common.Context, srcUris: string[]): Promise<number> {
    const mythroadDir = VmrpAssets.getMythroadDir(ctx);
    let count = 0;
    for (const srcUri of srcUris) {
      const name = srcUri.substring(srcUri.lastIndexOf('/') + 1);
      if (!name.toLowerCase().endsWith('.mrp')) continue;
      const dst = `${mythroadDir}/${name}`;
      try {
        const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
        const dstFile = fs.openSync(dst,
          fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
        await fs.copyFile(srcFile.fd, dstFile.fd);
        fs.closeSync(srcFile);
        fs.closeSync(dstFile);
        count++;
      } catch (e) {
        console.error(`${TAG}: importMrpBatch ${name} failed: ${JSON.stringify(e)}`);
      }
    }
    console.info(`${TAG}: importMrpBatch done, ${count}/${srcUris.length} imported`);
    return count;
  }

  // 递归收集目录下所有文件路径（不含目录本身）。
  private static collectFiles(dir: string, out: string[]): void {
    const names: string[] = fs.listFileSync(dir);
    for (const name of names) {
      const child = `${dir}/${name}`;
      if (fs.statSync(child).isDirectory()) {
        VmrpAssets.collectFiles(child, out);
      } else {
        out.push(child);
      }
    }
  }

  // 递归复制目录（保留结构）。dstDir 不存在会自动创建。
  private static copyDirRecursive(srcDir: string, dstDir: string): void {
    try { fs.mkdirSync(dstDir, true); } catch (e) { /* may exist */ }
    const names: string[] = fs.listFileSync(srcDir);
    for (const name of names) {
      const src = `${srcDir}/${name}`;
      const dst = `${dstDir}/${name}`;
      if (fs.statSync(src).isDirectory()) {
        VmrpAssets.copyDirRecursive(src, dst);
      } else {
        const sf = fs.openSync(src, fs.OpenMode.READ_ONLY);
        const df = fs.openSync(dst, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
        fs.copyFile(sf.fd, df.fd);
        fs.closeSync(sf);
        fs.closeSync(df);
      }
    }
  }

  // 递归删除目录（清空临时目录用）。
  private static removeDirRecursive(dir: string): void {
    const names: string[] = fs.listFileSync(dir);
    for (const name of names) {
      const child = `${dir}/${name}`;
      if (fs.statSync(child).isDirectory()) {
        VmrpAssets.removeDirRecursive(child);
      } else {
        fs.unlinkSync(child);
      }
    }
    fs.rmdirSync(dir);
  }

  // 备份 filesDir 到 zip 文件，通过 picker 写入 destUri（下载目录 URI）。
  // fileName 为用户自定义文件名（不含 .zip 后缀），传空则用默认名。
  // 用 compressFile 压缩整个目录（保留子目录结构）；compressFiles 会扁平化。
  static async backupToZip(ctx: common.Context, destUri: string,
                           fileName: string): Promise<boolean> {
    const cacheDir = ctx.cacheDir;
    const filesDir = ctx.filesDir;
    const zipPath = `${cacheDir}/vmrp_backup_tmp.zip`;
    // 确保文件名以 .zip 结尾
    const zipName = fileName.trim().length > 0
      ? (fileName.toLowerCase().endsWith('.zip') ? fileName : `${fileName}.zip`)
      : 'vmrp_backup.zip';
    try {
      try { fs.unlinkSync(zipPath); } catch (e) {}
      // 压缩整个 filesDir 目录（保留子目录结构）
      const options: zlib.Options = {
        level: zlib.CompressLevel.COMPRESS_LEVEL_DEFAULT_COMPRESSION
      };
      await zlib.compressFile(filesDir, zipPath, options);
      // DOWNLOAD 模式返回的是目录 URI，需拼接文件名再用 fileUri 转成路径。
      // 若 picker 已返回文件 URI（以 .zip 结尾）则直接用。
      const destPath = destUri.toLowerCase().endsWith('.zip')
        ? new fileUri.FileUri(destUri).path
        : new fileUri.FileUri(`${destUri}/${zipName}`).path;
      // 把 zip 复制到 picker 选定的目标位置（同名覆盖）
      const srcFile = fs.openSync(zipPath, fs.OpenMode.READ_ONLY);
      const dstFile = fs.openSync(destPath,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      await fs.copyFile(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      console.info(`${TAG}: backup OK -> ${destPath}`);
      return true;
    } catch (e) {
      console.error(`${TAG}: backup failed: ${JSON.stringify(e)}`);
      return false;
    } finally {
      try { fs.unlinkSync(zipPath); } catch (e) {}
    }
  }

  // 从 srcUri（picker 返回的 zip URI）恢复到 filesDir，覆盖同名文件。
  static async restoreFromZip(ctx: common.Context, srcUri: string): Promise<boolean> {
    const cacheDir = ctx.cacheDir;
    const filesDir = ctx.filesDir;
    const zipPath = `${cacheDir}/vmrp_restore.zip`;
    const tmpDir = `${cacheDir}/_vmrp_restore`;
    try {
      // 把用户选的 zip 复制到沙箱（zlib 只能操作沙箱路径）
      try { fs.unlinkSync(zipPath); } catch (e) {}
      const srcFile = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
      const dstFile = fs.openSync(zipPath, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
      await fs.copyFile(srcFile.fd, dstFile.fd);
      fs.closeSync(srcFile);
      fs.closeSync(dstFile);
      // 清理旧的临时解压目录
      try { VmrpAssets.removeDirRecursive(tmpDir); } catch (e) {}
      fs.mkdirSync(tmpDir, true);
      // 解压到临时目录（保留相对结构）
      await zlib.decompressFile(zipPath, tmpDir);
      // 覆盖复制到 filesDir（decompressFile 已会覆盖同名，但目标可能在不同根，这里手动覆盖确保）
      VmrpAssets.copyDirRecursive(tmpDir, filesDir);
      console.info(`${TAG}: restore OK`);
      return true;
    } catch (e) {
      console.error(`${TAG}: restore failed: ${JSON.stringify(e)}`);
      return false;
    } finally {
      try { VmrpAssets.removeDirRecursive(tmpDir); } catch (e) {}
      try { fs.unlinkSync(zipPath); } catch (e) {}
    }
  }
}
