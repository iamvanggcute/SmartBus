import UIKit

class MainTabBarController: UITabBarController {

    override func viewDidLoad() {
        super.viewDidLoad()
        setupAppearance()
        setupTabs()

        // Do any additional setup after loading the view.
    }
    private func setupTabs() {
        let homeNav = createNav(
            title : "Home",
            image : "house",
            selectedImage : "house.fill" ,
            root : HomeViewController()
        )
        let scanNav = createNav(
            title : "Scan",
            image : "qrcode",
            selectedImage : "qrcode.viewfinder" ,
            root : ScanViewController()
        )
        let tripNav = createNav (
            title : "Trip",
            image : "bus",
            selectedImage : "bus.fill" ,
            root : TripViewController()
        )
        let profileNav = createNav (
            title : "Profile",
            image : "person",
            selectedImage : "person.fill" ,
            root : ProfileViewController()
        )
        viewControllers = [homeNav, scanNav, tripNav, profileNav]
        selectedIndex = 2
    }
    private func createNav (
        title : String ,
        image : String ,
        selectedImage : String ,
        root : UIViewController
    ) -> UIViewController {
        let nav = UINavigationController(rootViewController: root)
        nav.tabBarItem = UITabBarItem(
            title: title,
            image: UIImage(systemName: image),
            selectedImage: UIImage(systemName: selectedImage)
        )
        return nav
    }
    private func setupAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear

        appearance.stackedLayoutAppearance.selected.iconColor = .systemBlue
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor.systemBlue
        ]

        appearance.stackedLayoutAppearance.normal.iconColor = .systemGray
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor.systemGray
        ]

        tabBar.standardAppearance = appearance

        if #available(iOS 15.0, *) {
            tabBar.scrollEdgeAppearance = appearance
        }
    }

}
