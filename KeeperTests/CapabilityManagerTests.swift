import XCTest
@testable import Keepur

@MainActor
final class CapabilityManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "selectedHive")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "selectedHive")
        super.tearDown()
    }

    func testFilterBeekeeperFromHives() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["beekeeper", "hive-personal", "hive-work"])
        XCTAssertEqual(manager.hives, ["hive-personal", "hive-work"])
    }

    func testAutoSetSelectedHiveWhenSingle() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["beekeeper", "hive-personal"])
        XCTAssertEqual(manager.selectedHive, "hive-personal")
    }

    func testDoesNotAutoSetWhenMultiple() {
        let manager = CapabilityManager()
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertNil(manager.selectedHive)
    }

    func testReconcileClearsStaleSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-old"
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertNil(manager.selectedHive)
    }

    func testReconcileKeepsValidSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-a"
        manager._setHivesForTesting(["hive-a", "hive-b"])
        XCTAssertEqual(manager.selectedHive, "hive-a")
    }

    func testSelectedHivePersistsAcrossInstances() {
        let manager1 = CapabilityManager()
        manager1.selectedHive = "hive-persistent"

        let manager2 = CapabilityManager()
        XCTAssertEqual(manager2.selectedHive, "hive-persistent")
    }

    func testClearAllRemovesSelectedHive() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-x"
        KeychainManager.clearAll()
        XCTAssertNil(manager.selectedHive)
    }

    func testEmptyListClearsSelection() {
        let manager = CapabilityManager()
        manager.selectedHive = "hive-a"
        manager._setHivesForTesting(["beekeeper"])
        XCTAssertNil(manager.selectedHive)
    }

    // MARK: - Role state (KPR-186)

    func testRoleStartsNil() {
        let manager = CapabilityManager()
        XCTAssertNil(manager.role)
    }

    func testRoleAdmin() {
        let manager = CapabilityManager()
        manager._setRoleForTesting("admin")
        XCTAssertEqual(manager.role, "admin")
    }

    func testRoleMember() {
        let manager = CapabilityManager()
        manager._setRoleForTesting("member")
        XCTAssertEqual(manager.role, "member")
    }

    func testRoleCanBeReset() {
        let manager = CapabilityManager()
        manager._setRoleForTesting("admin")
        manager._setRoleForTesting(nil)
        XCTAssertNil(manager.role)
    }
}
