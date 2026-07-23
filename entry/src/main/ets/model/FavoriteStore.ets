import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'vmrp_favorites';
const KEY_FAVORITES = 'favorite_paths';

export class FavoriteStore {
  private favSet: Set<string> = new Set();

  static async load(ctx: common.Context): Promise<FavoriteStore> {
    const store = new FavoriteStore();
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      const raw = (await pref.get(KEY_FAVORITES, '')) as string;
      if (raw.length > 0) {
        const arr = JSON.parse(raw) as string[];
        for (const p of arr) {
          store.favSet.add(p);
        }
      }
    } catch (_e) {}
    return store;
  }

  static loadSync(ctx: common.Context): FavoriteStore {
    const store = new FavoriteStore();
    try {
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      const raw = pref.getSync(KEY_FAVORITES, '') as string;
      if (raw.length > 0) {
        const arr = JSON.parse(raw) as string[];
        for (const p of arr) {
          store.favSet.add(p);
        }
      }
    } catch (_e) {}
    return store;
  }

  isFavorite(filePath: string): boolean {
    return this.favSet.has(filePath);
  }

  toggle(filePath: string): boolean {
    if (this.favSet.has(filePath)) {
      this.favSet.delete(filePath);
    } else {
      this.favSet.add(filePath);
    }
    return this.favSet.has(filePath);
  }

  getAll(): string[] {
    const arr: string[] = [];
    this.favSet.forEach((p: string) => { arr.push(p); });
    return arr;
  }

  async save(ctx: common.Context): Promise<void> {
    try {
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY_FAVORITES, JSON.stringify(this.getAll()));
      await pref.flush();
    } catch (_e) {}
  }

  saveSync(ctx: common.Context): void {
    try {
      const pref = preferences.getPreferencesSync(ctx, { name: PREF_NAME });
      pref.putSync(KEY_FAVORITES, JSON.stringify(this.getAll()));
      pref.flush();
    } catch (_e) {}
  }
}
