package example

enum class State { IDLE, RUNNING }
data class Item(val quantity: Int)
interface Worker {
    fun run(): Int
}
object Registry {
    val count: Int = 1
}
class Container {
    companion object Factory {
        fun create(): Container = Container()
    }
}
typealias Label = String
val limit: Int = 10
fun twice(value: Int): Int {
    return value * 2
}
