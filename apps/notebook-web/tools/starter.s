package starter

export starter_document

def starter_document():
  {format: "sputnik-notebook", version: 4, title: "Getting started", active_sheet: "main",
    sheets: [
      {id: "main", title: "Main", cells: [
        {id: "1", kind: "code", mode: "manual", source: "message = \"Hello, Sputnik!\"\nmessage\n"},
        {id: "2", kind: "text", source: "Run the first cell to see its result. Try changing the code, then save and run it again. Open the Order calculator board to try a notebook with inputs."}
      ]},
      {id: "order", title: "Order calculator", cells: [
        {id: "3", kind: "code", mode: "watch", source: "quantity = notebook.input(\"quantity\")\nquantity * 6\n"}
      ]}
    ], modules: [], auto_imports: [], dependencies: [],
    inputs: [{id: "quantity", title: "Quantity", type: "integer", default: 7, minimum: 1, maximum: 100}],
    boards: [{id: "order_board", title: "Order calculator", sheet: "order", columns: 2,
      components: [
        {id: "order_quantity", kind: "parameter_form", title: "Order quantity", fields: [{input: "quantity"}]},
        {id: "order_total", kind: "result", title: "Total at 6 per item", cell: "3"}
      ]}]}
