import Foundation
@main struct CreatorPresentationChecks {
    @MainActor static func main() throws {
        var checks=0
        func check(_ name:String,_ condition:Bool){precondition(condition,"FAIL "+name);checks+=1;print("PASS "+name)}
        let store=CreatorStore()
        func post(_ i:Int,_ title:String,isVideo:Bool=true)->CreatorPost {
            let id=String(Int64(7000000000000000000)+Int64(i))
            return CreatorPost(id:id,link:"https://www.douyin.com/video/"+id,title:title,author:"合成",createdAt:Int64(1700000000+i),diggCount:Int64(i*10000),collectCount:i==3 ? nil : Int64(i),isVideo:isVideo)
        }
        store.posts=[post(1,"alpha"),post(2,"beta"),post(3,"alpha-three"),post(4,"album",isVideo:false)]
        store.selectedIDs=Set(store.posts.map(\.id))
        check("cached result keeps canonical sort and video-only semantics",store.filteredPosts==CreatorCore.apply(store.posts.filter(\.isVideo),filter:store.filter) && store.skippedNonVideoCount==1)
        check("repeated getters preserve identical values",store.filteredPosts==store.filteredPosts && store.selectedPosts.count==3 && store.unknownFieldCount==0)
        store.filter.keyword="alpha"
        check("nested keyword mutation invalidates cached results",store.filteredPosts.count==2 && store.selectedPosts.count==2)
        store.filter.collectsAbove=0
        check("unknown-field count invalidated with filter",store.filteredPosts.count==1 && store.unknownFieldCount==1)
        store.filter.collectsAbove=nil;store.filter.keyword=""
        store.selectedIDs.remove(store.posts[0].id)
        check("selection mutation invalidates selected snapshot only",store.selectedPosts.count==2 && store.filteredPosts.count==3)
        store.posts[1].title="renamed"
        store.filter.keyword="renamed"
        check("in-place post edit invalidates previous snapshot",store.filteredPosts.count==1 && store.filteredPosts[0].title=="renamed")
        store.posts.append(post(5,"renamed-five"))
        check("append invalidates cached list",store.filteredPosts.count==2)
        store.selectedIDs.insert(store.posts.last!.id)
        check("newly selected appended post becomes visible",store.selectedPosts.count==2)
        store.posts.removeLast()
        check("removed post cannot remain in selected snapshot",store.filteredPosts.count==1 && store.selectedPosts.count==1)
        store.filter.fromDay="invalid"
        check("invalid date returns empty without stale results",store.filteredPosts.isEmpty && store.selectedPosts.isEmpty && store.filterError != nil)
        store.filter=CreatorFilter();store.posts[0].isVideo=false
        check("media-kind edit invalidates video count",store.skippedNonVideoCount==2 && store.filteredPosts.count==2)
        store.filter.sort = .likes
        check("sort mutation refreshes order",store.filteredPosts.first?.id==store.posts[2].id)
        store.selectPlatform(.bilibili)
        check("platform reset drops all cached results",store.filteredPosts.isEmpty && store.selectedPosts.isEmpty && store.unknownFieldCount==0 && store.skippedNonVideoCount==0)
        print("CreatorPresentationChecks: \(checks) passed")
    }
}
