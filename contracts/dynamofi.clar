;; Title: DynamoFi - Bitcoin-Native Automated Portfolio Manager
;;
;; Summary: A decentralized portfolio management protocol for Bitcoin users on Stacks Layer 2
;;
;; Description:
;; DynamoFi enables Bitcoin holders to create customizable investment portfolios with 
;; automatic rebalancing capabilities. Users can allocate their assets across multiple
;; tokens with specified target percentages and rebalance when market conditions change.
;; Built on Stacks to leverage Bitcoin's security while enabling DeFi capabilities.

;; Error Code Definitions

(define-constant ERR-NOT-AUTHORIZED (err u100)) ;; Unauthorized access attempt
(define-constant ERR-INVALID-PORTFOLIO (err u101)) ;; Portfolio doesn't exist or is invalid
(define-constant ERR-INSUFFICIENT-BALANCE (err u102)) ;; Insufficient funds for operation
(define-constant ERR-INVALID-TOKEN (err u103)) ;; Invalid token address provided
(define-constant ERR-REBALANCE-FAILED (err u104)) ;; Portfolio rebalancing operation failed
(define-constant ERR-PORTFOLIO-EXISTS (err u105)) ;; Portfolio already exists
(define-constant ERR-INVALID-PERCENTAGE (err u106)) ;; Invalid allocation percentage
(define-constant ERR-MAX-TOKENS-EXCEEDED (err u107)) ;; Exceeded maximum allowed tokens
(define-constant ERR-LENGTH-MISMATCH (err u108)) ;; Mismatch in input array lengths
(define-constant ERR-USER-STORAGE-FAILED (err u109)) ;; Failed to update user storage
(define-constant ERR-INVALID-TOKEN-ID (err u110)) ;; Invalid token ID in portfolio

;; Protocol Configuration

(define-data-var protocol-owner principal tx-sender)
(define-data-var portfolio-counter uint u0)
(define-data-var protocol-fee uint u25) ;; 0.25% in basis points

;; Protocol Constants

(define-constant MAX-TOKENS-PER-PORTFOLIO u10)
(define-constant BASIS-POINTS u10000) ;; 100% = 10000 basis points

;; Data Structures

(define-map Portfolios
  uint ;; portfolio-id
  {
    owner: principal,
    created-at: uint,
    last-rebalanced: uint,
    total-value: uint,
    active: bool,
    token-count: uint,
  }
)

(define-map PortfolioAssets
  {
    portfolio-id: uint,
    token-id: uint,
  }
  {
    target-percentage: uint,
    current-amount: uint,
    token-address: principal,
  }
)

(define-map UserPortfolios
  principal
  (list 20 uint)
)

;; Read-Only Functions

;; Retrieves portfolio details by ID
(define-read-only (get-portfolio (portfolio-id uint))
  (map-get? Portfolios portfolio-id)
)

;; Retrieves specific asset details within a portfolio
(define-read-only (get-portfolio-asset
    (portfolio-id uint)
    (token-id uint)
  )
  (map-get? PortfolioAssets {
    portfolio-id: portfolio-id,
    token-id: token-id,
  })
)

;; Returns list of portfolio IDs owned by a user
(define-read-only (get-user-portfolios (user principal))
  (default-to (list) (map-get? UserPortfolios user))
)

;; Calculates rebalancing requirements for a portfolio
(define-read-only (calculate-rebalance-amounts (portfolio-id uint))
  (let (
      (portfolio (unwrap! (get-portfolio portfolio-id) ERR-INVALID-PORTFOLIO))
      (total-value (get total-value portfolio))
    )
    (ok {
      portfolio-id: portfolio-id,
      total-value: total-value,
      needs-rebalance: (> (- stacks-block-height (get last-rebalanced portfolio)) u144),
    })
  )
)

;; Private Functions

;; Validates token ID within portfolio constraints
(define-private (validate-token-id
    (portfolio-id uint)
    (token-id uint)
  )
  (let ((portfolio (unwrap! (get-portfolio portfolio-id) false)))
    (and
      (< token-id MAX-TOKENS-PER-PORTFOLIO)
      (< token-id (get token-count portfolio))
      true
    )
  )
)

;; Validates percentage is within valid range (0-10000 basis points)
(define-private (validate-percentage (percentage uint))
  (and (>= percentage u0) (<= percentage BASIS-POINTS))
)

;; Validates sum of portfolio percentages
(define-private (validate-portfolio-percentages (percentages (list 10 uint)))
  (let ((total (fold + percentages u0)))
    (and
      ;; Check if total equals 100% (10000 basis points)
      (is-eq total BASIS-POINTS)
      ;; Check if each percentage is valid
      (fold and (map validate-percentage percentages) true)
    )
  )
)

;; Helper function for percentage validation
(define-private (check-percentage-sum
    (current-percentage uint)
    (valid bool)
  )
  (and valid (validate-percentage current-percentage))
)

;; Adds portfolio ID to user's portfolio list
(define-private (add-to-user-portfolios
    (user principal)
    (portfolio-id uint)
  )
  (let (
      (current-portfolios (get-user-portfolios user))
      (new-portfolios (unwrap! (as-max-len? (append current-portfolios portfolio-id) u20)
        ERR-USER-STORAGE-FAILED
      ))
    )
    (map-set UserPortfolios user new-portfolios)
    (ok true)
  )
)

;; Initializes a new portfolio asset
(define-private (initialize-portfolio-asset
    (index uint)
    (token principal)
    (percentage uint)
    (portfolio-id uint)
  )
  (if (>= percentage u0)
    (begin
      (map-set PortfolioAssets {
        portfolio-id: portfolio-id,
        token-id: index,
      } {
        target-percentage: percentage,
        current-amount: u0,
        token-address: token,
      })
      (ok true)
    )
    ERR-INVALID-TOKEN
  )
)

;; Helper function to initialize a token at a specific index
(define-private (initialize-token-at-index
    (index uint)
    (portfolio-id uint)
    (tokens (list 10 principal))
    (percentages (list 10 uint))
  )
  (begin
    (if (< index (len tokens))
      (initialize-portfolio-asset index
        (default-to 'SP000000000000000000002Q6VF78.dummy-token
          (element-at tokens index)
        )
        (default-to u0 (element-at percentages index)) portfolio-id
      )
      (ok true)
    )
  )
)

;; Public Functions

;; Creates a new portfolio with specified tokens and allocations
(define-public (create-portfolio
    (initial-tokens (list 10 principal))
    (percentages (list 10 uint))
  )
  (let (
      (portfolio-id (+ (var-get portfolio-counter) u1))
      (token-count (len initial-tokens))
      (percentage-count (len percentages))
    )
    (asserts! (<= token-count MAX-TOKENS-PER-PORTFOLIO) ERR-MAX-TOKENS-EXCEEDED)
    (asserts! (is-eq token-count percentage-count) ERR-LENGTH-MISMATCH)
    (asserts! (validate-portfolio-percentages percentages) ERR-INVALID-PERCENTAGE)
    (asserts! (>= token-count u2) ERR-INVALID-PORTFOLIO)
    ;; Ensure at least 2 tokens
    ;; Create portfolio
    (map-set Portfolios portfolio-id {
      owner: tx-sender,
      created-at: stacks-block-height,
      last-rebalanced: stacks-block-height,
      total-value: u0,
      active: true,
      token-count: token-count,
    })
    ;; Initialize first token (required minimum)
    (try! (initialize-token-at-index u0 portfolio-id initial-tokens percentages))
    ;; Initialize second token (required minimum)
    (try! (initialize-token-at-index u1 portfolio-id initial-tokens percentages))
    ;; Initialize third token if available
    (try! (initialize-token-at-index u2 portfolio-id initial-tokens percentages))
    ;; Initialize fourth token if available
    (try! (initialize-token-at-index u3 portfolio-id initial-tokens percentages))
    ;; Initialize fifth token if available
    (try! (initialize-token-at-index u4 portfolio-id initial-tokens percentages))
    ;; Initialize sixth token if available
    (try! (initialize-token-at-index u5 portfolio-id initial-tokens percentages))
    ;; Initialize seventh token if available
    (try! (initialize-token-at-index u6 portfolio-id initial-tokens percentages))
    ;; Initialize eighth token if available
    (try! (initialize-token-at-index u7 portfolio-id initial-tokens percentages))
    ;; Initialize ninth token if available
    (try! (initialize-token-at-index u8 portfolio-id initial-tokens percentages))
    ;; Initialize tenth token if available
    (try! (initialize-token-at-index u9 portfolio-id initial-tokens percentages))
    ;; Update user's portfolio list
    (try! (add-to-user-portfolios tx-sender portfolio-id))
    ;; Increment counter
    (var-set portfolio-counter portfolio-id)
    (ok portfolio-id)
  )
)