//
//  IPAContentView.swift
//  EasySign
//
//  Created by crazyball on 2024/11/30.
//

import Foundation
import SwiftUI

struct ResignSetting {
    var bundleId: String
    var displayName: String
    var version: String
    var buildVersion: String
    var entitlements: String
    
    init(bundleId: String = "", displayName: String = "", version: String = "", buildVersion: String = "", entitlements: String = "") {
        self.bundleId = bundleId
        self.displayName = displayName
        self.version = version
        self.buildVersion = buildVersion
        self.entitlements = entitlements
    }
}


struct IPAContentView: View {
    @Binding var resignSetting: ResignSetting
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("应用名称：")
                TextField("应用名称", text: $resignSetting.displayName)
            }
            HStack {
                Text("应用包名：")
                TextField("应用包名", text: $resignSetting.bundleId)
            }
            HStack {
                Text("应用版本：")
                TextField("应用版本", text: $resignSetting.version)
            }
            HStack {
                Text("构建版本：")
                TextField("构建版本", text: $resignSetting.buildVersion)
            }
            HStack {
                Text("权限信息：")
                TextEditor(text: $resignSetting.entitlements)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                
            }
        }
        .padding(.all)
        .frame(width: 600)
    }
}
