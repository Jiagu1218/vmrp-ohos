import { afterEach, describe, expect, it, vi } from "vitest";
import { SkyEngineE2e, SkyEngineWorkspace } from "../engine-e2e.js";
import fs from "fs";

describe("gfktjc", () => {
  let engine: SkyEngineE2e | undefined;
  let ws: SkyEngineWorkspace | undefined;

  afterEach(async () => {
    await engine?.close();
    engine = undefined;
    await ws?.dispose();
    ws = undefined;
  });

  it("渲染检测", async () => {
    // 每个用例使用独立的 mythroad 数据副本,避免并发执行时互相覆盖插件/缓存/存档。
    ws = await SkyEngineWorkspace.create();
    engine = await SkyEngineE2e.start("test/fixtures/gfktjc-v1005.mrp", { workDir: ws.dir });

    {
      // 等待进入图形加速提示界面
      await vi.waitFor(
        async () => {
          const screen = await engine!.screen("main");
          // rgb(240, 180, 64)
          expect(screen.pixel(116, 62)).toEqual([240, 180, 64]);
        },
        {
          timeout: 10_000,
          interval: 1_000,
        },
      );
    }
    {
      // 不启用图形加速
      await engine.key("RIGHT_SOFT", 1_000);
      await vi.waitFor(
        async () => {
          const screen = await engine!.screen("bgm-select");
          // rgb(240, 180, 64)
          expect(screen.pixel(116, 62)).not.toEqual([240, 180, 64]);
          // rgb(240, 180, 64)
          expect(screen.pixel(111, 132)).toEqual([240, 180, 64]);
        },
        {
          timeout: 10_000,
          interval: 1_000,
        },
      );
    }
  });
});
