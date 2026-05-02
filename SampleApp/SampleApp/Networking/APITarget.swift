// APITarget.swift — Moya TargetType describing all endpoints used in E2E recording tests.
// Base URL: http://127.0.0.1:4010 (Prism mock server)

import Foundation
import Moya

/// All API endpoints exercised by the E2E recording test.
///
/// Six cases cover the four Prism endpoints across success, error, and header-forcing paths.
enum APITarget {
    /// GET /users/me with valid auth — expects 200.
    case usersMe
    /// GET /users/me with invalid auth and `Prefer: code=401` — forces Prism to return 401.
    case usersMeUnauthorized
    /// GET /items?q=\(q)&limit=\(limit) — expects 200 list.
    case items(q: String, limit: Int)
    /// POST /items with JSON body — expects 201.
    case createItem(name: String, price: Double)
    /// GET /orders — expects 200.
    case orders
    /// GET /orders with `Prefer: code=500` — forces Prism to return 500.
    case ordersError
}

extension APITarget: TargetType {
    var baseURL: URL {
        // swiftlint:disable:next force_unwrapping
        URL(string: "http://127.0.0.1:4010")!
    }

    var path: String {
        switch self {
        case .usersMe, .usersMeUnauthorized:
            return "/users/me"
        case .items:
            return "/items"
        case .createItem:
            return "/items"
        case .orders, .ordersError:
            return "/orders"
        }
    }

    var method: Moya.Method {
        switch self {
        case .createItem:
            return .post
        default:
            return .get
        }
    }

    var task: Moya.Task {
        switch self {
        case .items(let q, let limit):
            return .requestParameters(
                parameters: ["q": q, "limit": limit],
                encoding: URLEncoding.queryString
            )
        case .createItem(let name, let price):
            return .requestParameters(
                parameters: ["name": name, "price": price],
                encoding: JSONEncoding.default
            )
        default:
            return .requestPlain
        }
    }

    var headers: [String: String]? {
        switch self {
        case .usersMe:
            return ["Authorization": "Bearer test-token"]
        case .usersMeUnauthorized:
            return [
                "Authorization": "Bearer invalid",
                "Prefer": "code=401"
            ]
        case .ordersError:
            return ["Prefer": "code=500"]
        default:
            return nil
        }
    }
}
