import Foundation

final class MovieService {
    static let shared = MovieService()
    private init() {}
    
    func fetchTrending(page: Int = 1, completion: @escaping (Result<[Movie], Error>) -> Void) {
        APIClient.shared.request(endpoint: .trending(page: page)) { (result: Result<PopularMoviesResponse, Error>) in
            self.handle(result, completion: completion)
        }
    }
    
    func fetchPopular(page: Int = 1, completion: @escaping (Result<[Movie], Error>) -> Void) {
        APIClient.shared.request(endpoint: .popular(page: page)) { (result: Result<PopularMoviesResponse, Error>) in
            self.handle(result, completion: completion)
        }
    }
    
    func fetchTopRated(page: Int = 1, completion: @escaping (Result<[Movie], Error>) -> Void) {
        APIClient.shared.request(endpoint: .topRated(page: page)) { (result: Result<PopularMoviesResponse, Error>) in
            self.handle(result, completion: completion)
        }
    }
    
    private func handle(_ result: Result<PopularMoviesResponse, Error>, completion: @escaping (Result<[Movie], Error>) -> Void) {
        switch result {
        case .success(let response):
            completion(.success(response.results))
        case .failure(let error):
            completion(.failure(error))
        }
    }
}
