# 子砚脚本目录

## 结构

```
scripts/
  README.md
  templates/
    01_basic_automation.lua    基础自动化模板
    02_vision_recognize.lua    视觉识别模板
    03_state_machine.lua       状态机模板
    04_app_validate.lua        应用/游戏测试模板（通用 Bundle）
```

## 规则

1. 必须 `Zy.Script.begin` 后只调 `Zy.*`
2. 点击只用 `tapDesign` / `tapRatio` / `tapHit`
3. 每次动作经 `Zy.Script.act` 或 `Zy.Verify.act`
4. 禁止固定物理坐标、录制回放、绕过模块直控

## 设备路径

部署后：`/private/var/mobile/Media/ZiYan/scripts/`
