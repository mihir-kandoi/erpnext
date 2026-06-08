"""Backfill the `product_bundle` version link on existing transaction rows.

Product Bundle is now versioned, and transactions record which version they were
packed from via a `product_bundle` (Link → Product Bundle) field on their item and
packed-item tables. This patch stamps that field on pre-existing rows.

Runs after ``submit_existing_product_bundles``, so each parent item has exactly one
migrated bundle (``PB-<item>-001``).

- **Selling / packed rows**: a row whose item is a bundle parent is stamped with that
  bundle's version (the field was newly added, so only blank rows are touched).
- **Buying rows**: the `product_bundle` field previously stored the parent *item code*
  (it was a Link → Item). Convert those legacy values to the bundle version name so the
  Link is valid. Idempotent: once converted, the value is a bundle name and no longer
  matches a `new_item_code`, so re-runs are no-ops.
"""

import frappe

# doctype -> column holding the bundle parent item code
SELLING_ITEM_TABLES = {
	"Sales Order Item": "item_code",
	"Delivery Note Item": "item_code",
	"Sales Invoice Item": "item_code",
	"POS Invoice Item": "item_code",
	"Quotation Item": "item_code",
	"Packed Item": "parent_item",
}

BUYING_ITEM_TABLES = ["Purchase Order Item", "Purchase Invoice Item", "Purchase Receipt Item"]


def execute():
	# parent item code -> migrated bundle version name (active version preferred)
	version_by_item = {}
	for bundle in frappe.get_all(
		"Product Bundle",
		filters={"docstatus": 1},
		fields=["name", "new_item_code"],
		order_by="is_active desc, creation asc",
	):
		version_by_item.setdefault(bundle.new_item_code, bundle.name)

	if not version_by_item:
		return

	for doctype, item_field in SELLING_ITEM_TABLES.items():
		if not frappe.db.has_column(doctype, "product_bundle"):
			continue
		table = frappe.qb.DocType(doctype)
		item_column = getattr(table, item_field)
		for item_code, version in version_by_item.items():
			(
				frappe.qb.update(table)
				.set(table.product_bundle, version)
				.where(
					(item_column == item_code)
					& ((table.product_bundle.isnull()) | (table.product_bundle == ""))
				)
			).run()

	for doctype in BUYING_ITEM_TABLES:
		if not frappe.db.has_column(doctype, "product_bundle"):
			continue
		table = frappe.qb.DocType(doctype)
		for item_code, version in version_by_item.items():
			# only legacy rows still holding the item code are matched
			(
				frappe.qb.update(table)
				.set(table.product_bundle, version)
				.where(table.product_bundle == item_code)
			).run()
