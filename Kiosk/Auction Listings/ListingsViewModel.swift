import Foundation
import RxSwift

typealias ShowDetailsClosure = (SaleArtwork) -> Void
typealias PresentModalClosure = (SaleArtwork) -> Void

protocol ListingsViewModelType {

    var auctionID: String { get }
    var syncInterval: NSTimeInterval { get }
    var pageSize: Int { get }
    var logSync: (NSDate) -> Void { get }
    var numberOfSaleArtworks: Int { get }

    var showSpinnerSignal: Observable<Bool>! { get }
    var gridSelectedSignal: Observable<Bool>! { get }
    var updatedContentsSignal: Observable<NSDate> { get }

    var schedule: (signal: Observable<AnyObject>) -> Observable<AnyObject> { get }

    func saleArtworkViewModelAtIndexPath(indexPath: NSIndexPath) -> SaleArtworkViewModel
    func showDetailsForSaleArtworkAtIndexPath(indexPath: NSIndexPath)
    func presentModalForSaleArtworkAtIndexPath(indexPath: NSIndexPath)
    func imageAspectRatioForSaleArtworkAtIndexPath(indexPath: NSIndexPath) -> CGFloat?
}

// Cheating here, should be in the instance but there's only ever one instance, so ¯\_(ツ)_/¯
private let backgroundScheduler = SerialDispatchQueueScheduler(globalConcurrentQueuePriority: .Default)

class ListingsViewModel: NSObject, ListingsViewModelType {

    // These are private to the view model – should not be accessed directly
    private var saleArtworks = Variable(Array<SaleArtwork>())
    private var sortedSaleArtworks: Variable<Array<SaleArtwork>>!

    let auctionID: String
    let pageSize: Int
    let syncInterval: NSTimeInterval
    let logSync: (NSDate) -> Void
    var schedule: (signal: Observable<AnyObject>) -> Observable<AnyObject>

    var numberOfSaleArtworks: Int {
        return saleArtworks.value.count
    }

    var showSpinnerSignal: Observable<Bool>!
    var gridSelectedSignal: Observable<Bool>!
    var updatedContentsSignal: Observable<NSDate> {
        return saleArtworks
            .asObservable()
            .distinctUntilChanged { (lhs, rhs) -> Bool in
                return lhs == rhs
            }
            .map { $0.count > 0 }
            .ignore(false)
            .map { _ in NSDate() }
    }

    let showDetails: ShowDetailsClosure
    let presentModal: PresentModalClosure

    init(selectedIndexSignal: Observable<Int>,
         showDetails: ShowDetailsClosure,
         presentModal: PresentModalClosure,
         pageSize: Int = 10,
         syncInterval: NSTimeInterval = SyncInterval,
         logSync:(NSDate) -> Void = ListingsViewModel.DefaultLogging,
         schedule: (signal: Observable<AnyObject>) -> Observable<AnyObject> = ListingsViewModel.DefaultScheduler,
         auctionID: String = AppSetup.sharedState.auctionID) {

        self.auctionID = auctionID
        self.showDetails = showDetails
        self.presentModal = presentModal
        self.pageSize = pageSize
        self.syncInterval = syncInterval
        self.logSync = logSync
        self.schedule = schedule

        super.init()

        setup(selectedIndexSignal)
    }

    // MARK: Private Methods

    private func setup(selectedIndexSignal: Observable<Int>) {

        recurringListingsRequestSignal()
            .takeUntil(rx_deallocated)
            .bindTo(saleArtworks)
            .addDisposableTo(rx_disposeBag)

        showSpinnerSignal = saleArtworks.map { saleArtworks in
            return saleArtworks.count == 0
        }

        gridSelectedSignal = selectedIndexSignal.map { ListingsViewModel.SwitchValues(rawValue: $0) == .Some(.Grid) }

        let distinctSaleArtworks: Observable<[SaleArtwork]> = saleArtworks
            .asObservable()
            .distinctUntilChanged { (lhs, rhs) -> Bool in
                return lhs == rhs
            }

        zip(distinctSaleArtworks, selectedIndexSignal)
            { (saleArtworks, selectedIndex) -> [SaleArtwork] in
                // Necessary to satisfy compiler.
                guard let switchValue = ListingsViewModel.SwitchValues(rawValue: selectedIndex) else { return saleArtworks }

                return switchValue.sortSaleArtworks(saleArtworks)
            }
            .bindTo(sortedSaleArtworks)
            .addDisposableTo(rx_disposeBag)
    }

    private func listingsRequestSignalForPage(page: Int) -> Observable<AnyObject> {
        return XAppRequest(.AuctionListings(id: auctionID, page: page, pageSize: self.pageSize)).filterSuccessfulStatusCodes().mapJSON()
    }

    // Repeatedly calls itself with page+1 until the count of the returned array is < pageSize.
    private func retrieveAllListingsRequestSignal(page: Int) -> Observable<AnyObject> {
        return create { [weak self] observer in
            guard let me = self else { return NopDisposable.instance }

            return me.listingsRequestSignalForPage(page).subscribeNext { object in
                guard let array = object as? Array<AnyObject> else { return }
                guard let me = self else { return }

                // This'll either be the next page request or empty.
                let nextPageSignal: Observable<AnyObject>

                // We must have more results to retrieve
                if array.count >= me.pageSize {
                    nextPageSignal = me.retrieveAllListingsRequestSignal(page+1)
                } else {
                    nextPageSignal = empty()
                }

                just(object)
                    .concat(nextPageSignal)
                    .subscribe(observer)
            }
        }
    }

    // Fetches all pages of the auction
    private func allListingsRequestSignal() -> Observable<[SaleArtwork]> {
        return schedule(signal: retrieveAllListingsRequestSignal(1)).reduce([AnyObject]())
            { (memo, object) in
                guard let array = object as? Array<AnyObject> else { return memo }
                return memo + array
            }
            .mapToObjectArray(SaleArtwork)
            .logServerError("Sale artworks failed to retrieve+parse")
            .catchErrorJustReturn([])
            .observeOn(MainScheduler.sharedInstance) // TODO: This MainScheduler should be injected as a dependency.
    }

    private func recurringListingsRequestSignal() -> Observable<Array<SaleArtwork>> {
        let recurringSignal = interval(syncInterval, MainScheduler.sharedInstance)
            .map { _ in NSDate() }
            .startWith(NSDate())
            .takeUntil(rx_deallocating)


        return recurringSignal
            .doOnNext(logSync)
            .flatMap { [weak self] _ in
                return self?.allListingsRequestSignal() ?? empty()
            }
            .map { [weak self] newSaleArtworks -> [SaleArtwork] in
                guard let me = self else { return [] }

                let currentSaleArtworks = me.saleArtworks.value

                // So we want to do here is pretty simple – if the existing and new arrays are of the same length,
                // then update the individual values in the current array and return the existing value.
                // If the array's length has changed, then we pass through the new array
                if newSaleArtworks.count == currentSaleArtworks.count {
                    if update(currentSaleArtworks, newSaleArtworks: newSaleArtworks) {
                        return currentSaleArtworks
                    }
                }

                return newSaleArtworks
            }
    }

    // MARK: Private class methods

    private class func DefaultLogging(date: NSDate) {
        #if (arch(i386) || arch(x86_64)) && os(iOS)
            logger.log("Syncing on \(date)")
        #endif
    }

    private class func DefaultScheduler(signal: Observable<AnyObject>) -> Observable<AnyObject> {
        return signal.observeOn(backgroundScheduler)
    }

    // MARK: Public methods

    func saleArtworkViewModelAtIndexPath(indexPath: NSIndexPath) -> SaleArtworkViewModel {
        return sortedSaleArtworks.value[indexPath.item].viewModel
    }

    func imageAspectRatioForSaleArtworkAtIndexPath(indexPath: NSIndexPath) -> CGFloat? {
        return sortedSaleArtworks.value[indexPath.item].artwork.defaultImage?.aspectRatio
    }

    func showDetailsForSaleArtworkAtIndexPath(indexPath: NSIndexPath) {
        showDetails(sortedSaleArtworks.value[indexPath.item])
    }

    func presentModalForSaleArtworkAtIndexPath(indexPath: NSIndexPath) {
        presentModal(sortedSaleArtworks.value[indexPath.item])
    }

    // MARK: - Switch Values

    enum SwitchValues: Int {
        case Grid = 0
        case LeastBids
        case MostBids
        case HighestCurrentBid
        case LowestCurrentBid
        case Alphabetical

        var name: String {
            switch self {
            case .Grid:
                return "Grid"
            case .LeastBids:
                return "Least Bids"
            case .MostBids:
                return "Most Bids"
            case .HighestCurrentBid:
                return "Highest Bid"
            case .LowestCurrentBid:
                return "Lowest Bid"
            case .Alphabetical:
                return "A–Z"
            }
        }

        func sortSaleArtworks(saleArtworks: [SaleArtwork]) -> [SaleArtwork] {
            switch self {
            case Grid:
                return saleArtworks
            case LeastBids:
                return saleArtworks.sort(leastBidsSort)
            case MostBids:
                return saleArtworks.sort(mostBidsSort)
            case HighestCurrentBid:
                return saleArtworks.sort(highestCurrentBidSort)
            case LowestCurrentBid:
                return saleArtworks.sort(lowestCurrentBidSort)
            case Alphabetical:
                return saleArtworks.sort(alphabeticalSort)
            }
        }

        static func allSwitchValues() -> [SwitchValues] {
            return [Grid, LeastBids, MostBids, HighestCurrentBid, LowestCurrentBid, Alphabetical]
        }

        static func allSwitchValueNames() -> [String] {
            return allSwitchValues().map{$0.name.uppercaseString}
        }
    }
}

// MARK: - Sorting Functions

protocol IntOrZeroable {
    var intOrZero: Int { get }
}

extension NSNumber: IntOrZeroable {
    var intOrZero: Int {
        return self as Int
    }
}

extension Optional where Wrapped: IntOrZeroable {
    var intOrZero: Int {
        return self.value?.intOrZero ?? 0
    }
}

func leastBidsSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return (lhs.bidCount.intOrZero) < (rhs.bidCount.intOrZero)
}

func mostBidsSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return !leastBidsSort(lhs, rhs)
}

func lowestCurrentBidSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return (lhs.highestBidCents.intOrZero) < (rhs.highestBidCents.intOrZero)
}

func highestCurrentBidSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return !lowestCurrentBidSort(lhs, rhs)
}

func alphabeticalSort(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return lhs.artwork.sortableArtistID().caseInsensitiveCompare(rhs.artwork.sortableArtistID()) == .OrderedAscending
}

func sortById(lhs: SaleArtwork, _ rhs: SaleArtwork) -> Bool {
    return lhs.id.caseInsensitiveCompare(rhs.id) == .OrderedAscending
}

private func update(currentSaleArtworks: [SaleArtwork], newSaleArtworks: [SaleArtwork]) -> Bool {
    assert(currentSaleArtworks.count == newSaleArtworks.count, "Arrays' counts must be equal.")
    // Updating the currentSaleArtworks is easy. Both are already sorted as they came from the API (by lot #).
    // Because we assume that their length is the same, we just do a linear scan through and
    // copy values from the new to the existing.

    let saleArtworksCount = currentSaleArtworks.count

    for var i = 0; i < saleArtworksCount; i++ {
        if currentSaleArtworks[i].id == newSaleArtworks[i].id {
            currentSaleArtworks[i].updateWithValues(newSaleArtworks[i])
        } else {
            // Failure: the list was the same size but had different artworks.
            return false
        }
    }

    return true
}
