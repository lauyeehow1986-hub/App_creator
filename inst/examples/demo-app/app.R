# Demo app for exercising the shinyalcatraz build pipeline end-to-end.
# Deliberately depends on nothing but shiny + base R: every package the
# app needs is one more thing build_wasm() must find a WASM binary for.
library(shiny)

ui <- fluidPage(
  titlePanel("shinyalcatraz demo"),
  sidebarLayout(
    sidebarPanel(
      fileInput("file", "Upload a CSV", accept = ".csv"),
      selectInput("column", "Column to plot", choices = NULL)
    ),
    mainPanel(
      plotOutput("plot"),
      tableOutput("table")
    )
  )
)

server <- function(input, output, session) {
  data <- reactive({
    if (is.null(input$file)) {
      data.frame(x = seq_len(20), y = sort(rnorm(20)))
    } else {
      utils::read.csv(input$file$datapath)
    }
  })

  observeEvent(data(), {
    numeric_cols <- names(data())[vapply(data(), is.numeric, logical(1))]
    updateSelectInput(session, "column", choices = numeric_cols)
  })

  output$plot <- renderPlot({
    req(input$column, input$column %in% names(data()))
    plot(data()[[input$column]], type = "l",
         xlab = "row", ylab = input$column, main = "shinyalcatraz demo")
  })

  output$table <- renderTable({
    utils::head(data(), 10)
  })
}

shinyApp(ui, server)
