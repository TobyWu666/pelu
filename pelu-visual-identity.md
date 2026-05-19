# Pelu 視覺識別方向

> 產品關鍵字：即時、安靜、可靠、輕量、iPhone 原生感、Mac 工具感。

Pelu 的視覺不需要像大型 SaaS 一樣強勢，也不適合做成可愛玩具感。它應該像一個放在 iPhone、Widget、Menu Bar 裡都自然存在的小工具：簡潔、現代、清楚，帶一點溫和的科技感。

---

## 1. 品牌定位

### 一句話

Pelu 是一個讓你在 iPhone 上即時掌握 Mac 上 Claude Code / Codex 用量的輕量監控工具。

### 視覺人格

- **簡潔**：介面資訊密度高，但不雜亂。
- **現代**：接近 Apple 原生 UI，乾淨、克制、重視間距。
- **可靠**：數字與狀態要清楚，避免過度裝飾。
- **溫和**：Pelu 是日常工具，不是警報系統；即使顯示用量接近上限，也不應該焦躁。
- **技術感**：可以有細緻的進度線、狀態點、卡片層次，但不要走駭客風、終端機綠黑風。

### 避免方向

- 避免太童趣、太寵物化。
- 避免大面積紫藍漸層。
- 避免太像金融 dashboard。
- 避免厚重陰影、玻璃擬態過重。
- 避免 logo 裡直接塞太多符號，例如手機、電腦、雲、AI、電量一起出現。

---

## 2. 主視覺方向

### 推薦方向：Soft Signal

主視覺核心是一個「柔和訊號環」：用簡潔的圓角線條、進度弧線、狀態點，表達 Mac 到 iPhone 的用量同步。

這個方向很適合 Pelu，因為產品本質是把看不見的用量狀態，轉成 iPhone 上一眼可讀的訊號。

### 視覺元素

- 圓角進度環
- 小型狀態點
- 細線資料流
- 淺色背景上的低對比層次
- 深色模式中使用柔和亮色，不使用高飽和霓虹

### 形狀語言

- 主形狀：圓角矩形、圓形、短弧線
- 線條：2px 到 3px，端點使用 round cap
- 圓角：中等偏大，接近 iOS Widget 感
- 卡片：8px 到 16px 圓角，依照平台元件決定

### 情緒

Pelu 看起來應該像「你放在桌邊的小型儀表」，不是「催你趕快處理的警報器」。

---

## 3. 配色系統

### 主色

| 名稱 | HEX | 用途 |
|---|---:|---|
| Pelu Teal | `#12B8A6` | 品牌主色、主要進度、重要狀態 |
| Ink | `#172026` | 主要文字、深色圖示 |
| Mist | `#F4F7F8` | App 淺色背景 |
| Surface | `#FFFFFF` | 卡片、浮層 |

Pelu Teal 是主品牌色。它比藍色更溫和，比綠色更現代，適合「用量狀態」與「連線同步」的語境。

### 輔助色

| 名稱 | HEX | 用途 |
|---|---:|---|
| Sky | `#5AA9FF` | Codex、雲端同步、次要資訊 |
| Lime | `#A4D65E` | 正常、安全、低用量狀態 |
| Amber | `#F5A524` | 接近限制、提醒 |
| Coral | `#FF6B5F` | 高用量、錯誤、需要注意 |

### 中性色

| 名稱 | HEX | 用途 |
|---|---:|---|
| Slate 900 | `#172026` | 主要文字 |
| Slate 700 | `#3D4A52` | 次要文字 |
| Slate 500 | `#71808A` | 輔助文字 |
| Slate 200 | `#DDE5E8` | 分隔線、邊框 |
| Slate 100 | `#EEF3F5` | 淺色區塊 |
| Slate 050 | `#F8FAFB` | 頁面背景 |

### 深色模式

| 名稱 | HEX | 用途 |
|---|---:|---|
| Night | `#0D1216` | 深色背景 |
| Night Surface | `#151C21` | 深色卡片 |
| Night Border | `#253039` | 深色邊框 |
| Text Primary | `#F4F7F8` | 深色主要文字 |
| Text Secondary | `#A9B5BC` | 深色次要文字 |
| Pelu Teal Bright | `#2ED3C1` | 深色模式主色 |

### 狀態配色

| 狀態 | 顏色 | 使用情境 |
|---|---|---|
| 正常 | `#12B8A6` 或 `#A4D65E` | 0% 到 70% |
| 注意 | `#F5A524` | 70% 到 85% |
| 警示 | `#FF6B5F` | 85% 以上 |
| 離線 | `#71808A` | Mac 不可達、雲端資料過期 |

### 配色比例

- 背景與中性色：70%
- 品牌主色：20%
- 警示與輔助色：10%

不要讓整個介面都變成 teal。Pelu Teal 應該像訊號一樣出現，讓重要資訊浮出來。

---

## 4. Logo 方向

### 推薦 Logo 概念：P Signal

Logo 以字母 **P** 為基礎，把 P 的內圈做成一個「用量環 / 訊號環」。整體可以是單線條或實心圖形，保持在小尺寸 Widget、Menu Bar、App icon 中都可辨識。

### 組成

- 外形是一個圓潤的 P。
- P 的圓弧像一段進度環。
- 右上或內圈可放一個小狀態點，代表即時更新。
- 不要直接畫手機或電腦，避免 logo 太具象。

### Logo 風格

- 圓角、簡潔、幾何。
- 線條厚度穩定。
- 小尺寸時只保留 P + 圓弧，不保留細節。
- 可做單色版本，方便 menu bar、widget、深色模式使用。

### App Icon 版本

建議使用：

- 背景：`#12B8A6` 到 `#2ED3C1` 的極輕微垂直漸層，或單色 `#12B8A6`
- 圖形：白色 P Signal
- 圓角：使用 iOS app icon 系統圓角，不在圖形內額外畫外框

App icon 不要塞數字、百分比、Mac/iPhone 圖示。Icon 的任務是記住 Pelu，不是解釋所有功能。

### Menu Bar 版本

macOS menu bar 圖示建議使用單色線條版本：

- 正常：系統模板色
- 更新中：P 旁邊出現小點
- 離線：降低透明度或使用斜線版本

Menu bar 圖示應該能在 16px 到 18px 仍然清楚。

---

## 5. 字體與排版

### 字體

優先使用 Apple 系統字體：

- iOS / macOS：SF Pro
- 數字：SF Pro Rounded 或 SF Mono 視情境使用

### 數字風格

用量百分比是 Pelu 的主角。數字要大、清楚、穩定。

建議：

- Dashboard 主要百分比：使用大字重，例如 Semibold
- 卡片內小數字：使用 Medium
- 技術資訊或時間戳：可用 SF Mono，增加儀表感

### 排版原則

- 標題短，不寫說明文堆在畫面上。
- 數字優先，文字輔助。
- 同一張卡片中最多放一個主要數字。
- 重要狀態用顏色和圖形輔助，不只靠文字。

---

## 6. UI 視覺應用

### Dashboard

建議主畫面由 2 到 4 張卡片組成：

- Claude Code 用量
- Codex 用量
- 今日花費
- 同步狀態

每張卡片都應該有：

- 一個主要數字
- 一條細進度線或小進度環
- 一個狀態文字，例如「剛剛更新」、「Mac 本地連線」、「雲端同步」

### Widget

Widget 要比主 App 更克制：

- 小尺寸：只顯示一個主要百分比 + 小狀態點
- 中尺寸：顯示 Claude / Codex 兩條進度
- 鎖屏：只顯示最重要的一個數字

Widget 不要放太多文案。它的價值是一眼看懂。

### Live Activity

Live Activity 可以用細長進度條：

- 左側：Pelu 小圖示
- 中間：Claude / Codex 目前用量
- 右側：更新狀態或剩餘百分比

Dynamic Island 展開時再顯示更多細節。

---

## 7. Logo 草圖描述

給設計師或 AI 產圖工具的描述：

```text
A minimal modern app logo for "Pelu", based on a rounded geometric letter P. The bowl of the P forms a clean progress ring, with a small status dot suggesting live sync. Simple, friendly, precise, Apple-style utility app aesthetic. Use white symbol on a teal background. Avoid mascots, devices, clouds, complex gradients, and excessive detail.
```

中文描述：

```text
為 Pelu 設計一個簡潔現代的 App logo。圖形以圓潤幾何字母 P 為核心，P 的內圈像一段用量進度環，旁邊有一個小狀態點，表達即時同步。整體要像 Apple 生態系中的工具型 App，乾淨、可靠、溫和。使用白色圖形搭配 teal 綠藍背景。不要吉祥物、不要手機電腦雲朵、不要複雜漸層。
```

---

## 8. 最終建議

Pelu 的主視覺建議定為：

- **主視覺概念**：Soft Signal
- **主色**：Pelu Teal `#12B8A6`
- **輔助色**：Sky `#5AA9FF`、Amber `#F5A524`、Coral `#FF6B5F`
- **Logo**：P Signal，圓潤字母 P + 用量環 + 狀態點
- **整體風格**：Apple 原生工具感、低噪音 dashboard、乾淨卡片、清楚數字

這套方向可以同時支撐 iPhone App、Widget、Live Activity、macOS Menu Bar，不會因為平台變小就失去辨識度。
