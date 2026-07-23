import { i18n } from '@kit.LocalizationKit';
import { MrpInfoData } from '../vmrp/MrpInfo';

export const CARD_RADIUS = 20;

export const DELETE_TRANSITION = TransitionEffect.OPACITY
  .combine(TransitionEffect.scale({ x: 0.8, y: 0.8 }))
  .animation({ duration: 300, curve: Curve.EaseInOut });

export interface MrpGroup {
  letter: string;
  items: MrpInfoData[];
}

export interface FlatItem {
  type: string;
  letter: string;
  data: MrpInfoData;
  key: string;
}

const latnTransliterator: i18n.Transliterator = i18n.Transliterator.getInstance('Any-Latn');
const asciiTransliterator: i18n.Transliterator = i18n.Transliterator.getInstance('Latin-ASCII');

export function emptyMrpInfoData(): MrpInfoData {
  const d: MrpInfoData = {
    filename: '', appname: '', appid: 0, version: 0,
    vendor: '', description: '', fileSize: 0, filePath: '', mtime: 0
  };
  return d;
}

export function getPinyinInitial(name: string): string {
  if (name.length === 0) return '#';
  const ch = name.charAt(0).toUpperCase();
  if (ch >= 'A' && ch <= 'Z') return ch;
  try {
    const latn = latnTransliterator.transform(name.charAt(0));
    const ascii = asciiTransliterator.transform(latn);
    const letter = ascii.charAt(0).toUpperCase();
    if (letter >= 'A' && letter <= 'Z') return letter;
  } catch (_e) {}
  return '#';
}

export function groupByLetter(list: MrpInfoData[]): MrpGroup[] {
  const map: Record<string, MrpInfoData[]> = {};
  const order: string[] = [];
  for (const item of list) {
    const letter = getPinyinInitial(item.appname);
    if (!map[letter]) {
      map[letter] = [];
      order.push(letter);
    }
    map[letter].push(item);
  }
  order.sort();
  const groups: MrpGroup[] = [];
  for (const letter of order) {
    groups.push({ letter: letter, items: map[letter] });
  }
  return groups;
}

export function buildIndexArray(groups: MrpGroup[]): string[] {
  const arr: string[] = [];
  for (const g of groups) {
    arr.push(g.letter);
  }
  if (arr.length === 0) return ['#'];
  return arr;
}
