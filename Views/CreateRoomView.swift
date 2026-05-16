import SwiftUI

struct CreateRoomView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vpnManager: VPNManager
    @State private var inviteCode = ""
    @State private var isCopied = false
    
    var body: some View {
        ZStack {
            Color(red: 0.11, green: 0.11, blue: 0.12).ignoresSafeArea()
            
            VStack(spacing: 30) {
                Image(systemName: "house.circle.fill")
                    .font(.system(size: 70))
                    .foregroundColor(Color(hex: "D34C3B"))
                
                Text("你的邀请码")
                    .font(.title2)
                
                Text(inviteCode)
                    .font(.system(.title, design: .monospaced))
                    .padding()
                    .background(BlurView(style: .dark))
                    .cornerRadius(12)
                
                Button(action: copyCode) {
                    HStack {
                        Image(systemName: isCopied ? "checkmark.circle.fill" : "doc.on.doc.fill")
                        Text(isCopied ? "已复制" : "复制邀请码")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(hex: "D34C3B"))
                    .cornerRadius(12)
                }
                .disabled(isCopied)
                
                if vpnManager.status == .connected {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                        Text("联机网络已就绪")
                    }
                }
                
                Spacer()
                
                Button("关闭房间", role: .destructive) {
                    vpnManager.stopVPN()
                    dismiss()
                }
                .padding()
            }
            .padding()
        }
        .onAppear {
            inviteCode = InviteCodeService.generate()
            UIPasteboard.general.string = inviteCode
            isCopied = true
            vpnManager.startWithInviteCode(inviteCode) { _ in }
        }
    }
    
    private func copyCode() {
        UIPasteboard.general.string = inviteCode
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            isCopied = false
        }
    }
}