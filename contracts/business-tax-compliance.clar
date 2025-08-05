;; Business Tax Compliance Monitoring Contract
;; Ensures businesses pay required local taxes and fees

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-BUSINESS-NOT-FOUND (err u201))
(define-constant ERR-INVALID-AMOUNT (err u202))
(define-constant ERR-ALREADY-COMPLIANT (err u203))
(define-constant ERR-LICENSE-EXPIRED (err u204))

;; Data Variables
(define-data-var next-business-id uint u1)
(define-data-var base-license-fee uint u500000) ;; 5 STX base fee
(define-data-var compliance-penalty uint u100000) ;; 1 STX penalty

;; Data Maps
(define-map businesses
  { business-id: uint }
  {
    owner: principal,
    business-name: (string-ascii 100),
    business-type: (string-ascii 50),
    license-fee: uint,
    compliance-status: (string-ascii 20),
    license-expiry: uint,
    last-payment: (optional uint),
    violations: uint,
    total-penalties: uint
  }
)

(define-map business-payments
  { business-id: uint, payment-id: uint }
  {
    payment-type: (string-ascii 30),
    amount: uint,
    payment-date: uint
  }
)

(define-map owner-businesses
  { owner: principal }
  { business-ids: (list 50 uint) }
)

(define-map compliance-violations
  { business-id: uint, violation-id: uint }
  {
    violation-type: (string-ascii 50),
    violation-date: uint,
    penalty-amount: uint,
    resolved: bool
  }
)

;; Private Functions
(define-private (calculate-license-fee (business-type (string-ascii 50)))
  (if (is-eq business-type "RESTAURANT")
    (* (var-get base-license-fee) u2)
    (if (is-eq business-type "RETAIL")
      (var-get base-license-fee)
      (* (var-get base-license-fee) u3) ;; Higher fee for other types
    )
  )
)

(define-private (is-authorized (caller principal))
  (is-eq caller CONTRACT-OWNER)
)

(define-private (is-license-expired (expiry-date uint))
  (> block-height expiry-date)
)

;; Public Functions

;; Register a new business
(define-public (register-business
  (owner principal)
  (business-name (string-ascii 100))
  (business-type (string-ascii 50))
  (license-expiry uint))
  (let
    (
      (business-id (var-get next-business-id))
      (license-fee (calculate-license-fee business-type))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> license-expiry block-height) ERR-LICENSE-EXPIRED)

    (map-set businesses
      { business-id: business-id }
      {
        owner: owner,
        business-name: business-name,
        business-type: business-type,
        license-fee: license-fee,
        compliance-status: "PENDING",
        license-expiry: license-expiry,
        last-payment: none,
        violations: u0,
        total-penalties: u0
      }
    )

    ;; Update owner's business list
    (let
      (
        (current-businesses (default-to { business-ids: (list) }
                           (map-get? owner-businesses { owner: owner })))
        (updated-list (unwrap-panic (as-max-len?
                      (append (get business-ids current-businesses) business-id) u50)))
      )
      (map-set owner-businesses
        { owner: owner }
        { business-ids: updated-list }
      )
    )

    (var-set next-business-id (+ business-id u1))
    (ok business-id)
  )
)

;; Pay business license fee
(define-public (pay-license-fee (business-id uint) (payment-amount uint))
  (let
    (
      (business-data (unwrap! (map-get? businesses { business-id: business-id }) ERR-BUSINESS-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner business-data)) ERR-NOT-AUTHORIZED)
    (asserts! (>= payment-amount (get license-fee business-data)) ERR-INVALID-AMOUNT)
    (asserts! (not (is-license-expired (get license-expiry business-data))) ERR-LICENSE-EXPIRED)

    (map-set businesses
      { business-id: business-id }
      (merge business-data {
        compliance-status: "COMPLIANT",
        last-payment: (some block-height)
      })
    )

    (ok true)
  )
)

;; Record compliance violation
(define-public (record-violation
  (business-id uint)
  (violation-type (string-ascii 50))
  (penalty-amount uint))
  (let
    (
      (business-data (unwrap! (map-get? businesses { business-id: business-id }) ERR-BUSINESS-NOT-FOUND))
      (violation-id (get violations business-data))
    )
    (asserts! (is-authorized tx-sender) ERR-NOT-AUTHORIZED)
    (asserts! (> penalty-amount u0) ERR-INVALID-AMOUNT)

    ;; Record the violation
    (map-set compliance-violations
      { business-id: business-id, violation-id: violation-id }
      {
        violation-type: violation-type,
        violation-date: block-height,
        penalty-amount: penalty-amount,
        resolved: false
      }
    )

    ;; Update business record
    (map-set businesses
      { business-id: business-id }
      (merge business-data {
        violations: (+ violation-id u1),
        total-penalties: (+ (get total-penalties business-data) penalty-amount),
        compliance-status: "VIOLATION"
      })
    )

    (ok violation-id)
  )
)

;; Resolve violation by paying penalty
(define-public (resolve-violation (business-id uint) (violation-id uint) (payment-amount uint))
  (let
    (
      (business-data (unwrap! (map-get? businesses { business-id: business-id }) ERR-BUSINESS-NOT-FOUND))
      (violation-data (unwrap! (map-get? compliance-violations
                               { business-id: business-id, violation-id: violation-id })
                               ERR-BUSINESS-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner business-data)) ERR-NOT-AUTHORIZED)
    (asserts! (>= payment-amount (get penalty-amount violation-data)) ERR-INVALID-AMOUNT)
    (asserts! (not (get resolved violation-data)) ERR-ALREADY-COMPLIANT)

    ;; Mark violation as resolved
    (map-set compliance-violations
      { business-id: business-id, violation-id: violation-id }
      (merge violation-data { resolved: true })
    )

    ;; Update compliance status if all violations resolved
    (let
      (
        (remaining-penalties (- (get total-penalties business-data) (get penalty-amount violation-data)))
      )
      (map-set businesses
        { business-id: business-id }
        (merge business-data {
          total-penalties: remaining-penalties,
          compliance-status: (if (is-eq remaining-penalties u0) "COMPLIANT" "VIOLATION")
        })
      )
    )

    (ok true)
  )
)

;; Renew business license
(define-public (renew-license (business-id uint) (new-expiry uint) (payment-amount uint))
  (let
    (
      (business-data (unwrap! (map-get? businesses { business-id: business-id }) ERR-BUSINESS-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get owner business-data)) ERR-NOT-AUTHORIZED)
    (asserts! (>= payment-amount (get license-fee business-data)) ERR-INVALID-AMOUNT)
    (asserts! (> new-expiry block-height) ERR-LICENSE-EXPIRED)

    (map-set businesses
      { business-id: business-id }
      (merge business-data {
        license-expiry: new-expiry,
        last-payment: (some block-height),
        compliance-status: "COMPLIANT"
      })
    )

    (ok true)
  )
)

;; Read-only Functions

;; Get business details
(define-read-only (get-business (business-id uint))
  (map-get? businesses { business-id: business-id })
)

;; Get businesses owned by a principal
(define-read-only (get-owner-businesses (owner principal))
  (map-get? owner-businesses { owner: owner })
)

;; Check if business is compliant
(define-read-only (is-business-compliant (business-id uint))
  (match (map-get? businesses { business-id: business-id })
    business-data (and
                   (is-eq (get compliance-status business-data) "COMPLIANT")
                   (not (is-license-expired (get license-expiry business-data))))
    false
  )
)

;; Get violation details
(define-read-only (get-violation (business-id uint) (violation-id uint))
  (map-get? compliance-violations { business-id: business-id, violation-id: violation-id })
)

;; Get total amount owed by business
(define-read-only (get-total-amount-owed (business-id uint))
  (match (map-get? businesses { business-id: business-id })
    business-data (get total-penalties business-data)
    u0
  )
)

;; Check if license is expired
(define-read-only (is-business-license-expired (business-id uint))
  (match (map-get? businesses { business-id: business-id })
    business-data (is-license-expired (get license-expiry business-data))
    true
  )
)
