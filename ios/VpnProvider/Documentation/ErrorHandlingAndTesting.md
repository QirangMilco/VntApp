# VPN Provider 错误处理与测试指南

本文档详细描述了VPN Provider中的错误处理机制、内存管理优化以及测试功能的使用方法。

## 1. 错误处理架构

### 1.1 错误类型定义

VPN Provider使用`VpnError`枚举定义了所有可能的错误类型：

- `configNotFound`: 配置文件未找到
- `initializationFailed(reason: String)`: 初始化失败，包含失败原因
- `connectionError(reason: String)`: 连接错误，包含错误原因
- `packetProcessError(reason: String)`: 数据包处理错误
- `interfaceError(reason: String)`: 网络接口错误
- `memoryError`: 内存不足错误

### 1.2 错误记录与报告机制

- **错误历史记录**: 所有错误都被记录在`errorHistory`数组中
- **错误报告**: 通过`sendErrorReport`方法将错误信息发送到主应用
- **测试模式报告**: 测试模式下会生成更详细的错误报告

### 1.3 错误恢复策略

- **配置错误恢复**: 尝试从备用源加载配置或使用默认配置
- **内存错误恢复**: 触发清理操作并记录详细的内存使用情况
- **连接错误恢复**: 实现自动重试机制，在尝试多次后才通知用户
- **数据包处理错误恢复**: 丢弃有问题的数据包并保持VPN服务运行

## 2. 内存管理优化

### 2.1 内存监控

- `checkMemoryUsage()`: 定期检查内存使用情况，在接近阈值时发出警告
- `getFreeMemory()`: 获取当前可用内存大小
- `checkMemoryAvailability()`: 检查是否有足够内存执行操作

### 2.2 内存分配安全

- `allocateAndCopyString()`: 安全地分配和复制字符串，防止内存泄漏
- `freeVntConfigMemory()`: 在错误情况下释放配置内存

### 2.3 内存限制与保护

- 数据包处理中的内存使用控制
- 资源密集型操作前的内存检查
- 测试模式下的内存使用报告

## 3. 测试模式功能

### 3.1 启用测试模式

通过向VPN Provider发送以下消息启用测试模式：

```json
{
  "type": "test_mode",
  "enabled": true
}
```

### 3.2 注入测试错误

测试模式下，可以注入各种类型的错误以测试错误处理机制：

```json
{
  "type": "test_error",
  "error_type": "connectionError"
}
```

可用的错误类型：
- `configNotFound`
- `initializationFailed`
- `connectionError`
- `packetProcessError`
- `interfaceError`
- `memoryError`

### 3.3 获取详细状态信息

获取VPN详细状态信息，包括运行状态、统计数据和错误历史：

```json
{
  "type": "detailed_state"
}
```

### 3.4 内存检查

检查当前内存使用情况：

```json
{
  "type": "memory_check"
}
```

### 3.5 统计信息管理

- 获取统计信息：
  ```json
  {
    "type": "get_stats"
  }
  ```

- 重置统计信息：
  ```json
  {
    "type": "reset_stats"
  }
  ```

## 4. 配置验证

VPN Provider实现了全面的配置验证功能，确保：

- 必需字段验证（token、device_id等）
- 端口范围验证
- 旧配置兼容处理
- 配置完整性检查

## 5. 错误恢复流程示例

1. 检测到错误
2. 记录错误到`errorHistory`
3. 尝试恢复（如果可能）
4. 在测试模式下发送详细报告
5. 更新统计信息
6. 根据错误严重性决定是否通知用户

## 6. 最佳实践

- 在生产环境中禁用测试模式
- 定期监控错误日志
- 对VPN连接问题优先检查网络状态和配置完整性
- 注意内存使用情况，特别是在处理大量并发连接时

---

## 版本历史

- **1.0**: 初始文档
- **1.1**: 添加测试模式功能说明
- **1.2**: 更新错误恢复策略描述