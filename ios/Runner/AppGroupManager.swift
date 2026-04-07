import Foundation

class AppGroupManager {
    
    static let shared = AppGroupManager()
    
    private let appGroupName = "group.xyz.QRTech.vntApp"
    private var userDefaults: UserDefaults?
    
    init() {
        userDefaults = UserDefaults(suiteName: appGroupName)
    }
    
    // 保存数据到App Group
    func save<T: Codable>(data: T, forKey key: String) -> Bool {
        do {
            let encoder = JSONEncoder()
            let jsonData = try encoder.encode(data)
            userDefaults?.set(jsonData, forKey: key)
            userDefaults?.synchronize()
            return true
        } catch {
            print("Error saving data to App Group: \(error.localizedDescription)")
            return false
        }
    }
    
    // 从App Group读取数据
    func load<T: Codable>(forKey key: String, type: T.Type) -> T? {
        guard let data = userDefaults?.data(forKey: key) else {
            return nil
        }
        
        do {
            let decoder = JSONDecoder()
            let decodedData = try decoder.decode(type, from: data)
            return decodedData
        } catch {
            print("Error loading data from App Group: \(error.localizedDescription)")
            return nil
        }
    }
    
    // 保存字典到App Group
    func saveDictionary(_ dictionary: [String: Any], forKey key: String) -> Bool {
        userDefaults?.set(dictionary, forKey: key)
        return userDefaults?.synchronize() ?? false
    }
    
    // 从App Group读取字典
    func loadDictionary(forKey key: String) -> [String: Any]? {
        return userDefaults?.dictionary(forKey: key)
    }
    
    // 删除指定键的数据
    func remove(forKey key: String) {
        userDefaults?.removeObject(forKey: key)
        userDefaults?.synchronize()
    }
    
    // 检查App Group是否可用
    func isAppGroupAvailable() -> Bool {
        return userDefaults != nil
    }
    
    // 获取App Group的URL用于文件共享
    func getAppGroupContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
    }
    
    // 保存文件到App Group共享容器
    func saveFile(data: Data, filename: String) -> Bool {
        guard let containerURL = getAppGroupContainerURL() else {
            return false
        }
        
        let fileURL = containerURL.appendingPathComponent(filename)
        
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("Error saving file to App Group: \(error.localizedDescription)")
            return false
        }
    }
    
    // 从App Group共享容器读取文件
    func readFile(filename: String) -> Data? {
        guard let containerURL = getAppGroupContainerURL() else {
            return nil
        }
        
        let fileURL = containerURL.appendingPathComponent(filename)
        
        do {
            let data = try Data(contentsOf: fileURL)
            return data
        } catch {
            print("Error reading file from App Group: \(error.localizedDescription)")
            return nil
        }
    }
}