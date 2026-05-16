import Foundation

// Rust FFI 函数声明
@_silgen_name("init_logger")
func rust_init_logger(_ path: UnsafePointer<CChar>, _ level: UnsafePointer<CChar>, _ subsystem: UnsafePointer<CChar>, _ errMsg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> CInt

@_silgen_name("run_network_instance")
func rust_run_network_instance(_ cfgStr: UnsafePointer<CChar>, _ errMsg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> CInt

@_silgen_name("set_tun_fd")
func rust_set_tun_fd(_ fd: CInt, _ errMsg: UnsafeMutablePointer<UnsafePointer<CChar>?>) -> CInt

@_silgen_name("stop_network_instance")
func rust_stop_network_instance() -> CInt

@_silgen_name("free_string")
func rust_free_string(_ ptr: UnsafePointer<CChar>?)